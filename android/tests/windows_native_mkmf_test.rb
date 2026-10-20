# Exercise Ruby 3.4.10's real mkmf link gate with a host Ruby helper, never a
# compiler or the generated ELF fixture. Every generated file stays in temp.
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"

module WindowsNativeMkmfTest
  ROOT = File.expand_path("../..", __dir__)
  BEFORE_SHA = "e67c3ef2f1f1cafd596aba005625e7b6f75c756ffe1b6ba79b1fe10ce84ee55e"
  AFTER_SHA = "21cb127b857296a49eae1d550d5e11ca2152496f3163009ddd73fae2eb75d11e"
  PATCH_SHA = "35bbbd7d8ba347bc4d6c9dc4887f8f5eba4c1bbc9ebe5caa679b9e8794e67877"

  def self.check(condition, message)
    raise message unless condition
    @checks = @checks.to_i + 1
  end

  def self.git(*args)
    stdout, stderr, status = Open3.capture3("git", *args)
    raise "git #{args.inspect} failed: #{stderr}\n#{stdout}" unless status.success?
    stdout
  end

  def self.worker(source, work, report_path, variant, host_ruby)
    @checks = 0
    source = File.expand_path(source)
    FileUtils.mkdir_p(work)
    # This is the complete real source, rather than a copied implementation of
    # its predicate. Only command generation is replaced below.
    load source
    probe = Object.new.extend(MakeMakefile)
    location = probe.method(:try_link0).source_location
    check(File.expand_path(location.first) == source, "try_link0 did not come from the selected full mkmf.rb")
    check(Digest::SHA256.file(source).hexdigest == (variant == "old" ? BEFORE_SHA : AFTER_SHA), "worker source hash differs")
    helper = File.join(work, "host-link-helper.rb")
    File.write(helper, <<~'RUBY')
      output, mode, code = ARGV
      unless mode == "no-output"
        # A 64-byte AArch64 ELF header is opaque test data, never executed.
        elf = "\x7fELF\x02\x01\x01".b.ljust(64, "\0")
        elf[16, 2] = [2].pack("v")
        elf[18, 2] = [183].pack("v")
        elf[20, 4] = [1].pack("V")
        elf[52, 2] = [64].pack("v")
        File.binwrite(output, elf)
        File.chmod(mode == "executable" ? 0o755 : 0o644, output)
      end
      warn "expected host helper warning" if mode == "warning"
      exit Integer(code)
    RUBY
    cases = [
      {name: "mingw_regular", origin: "x64-mingw-ucrt", patched: true},
      {name: "mswin_regular", origin: "x64-mswin64_140", patched: true},
      {name: "failed_with_output", origin: "x64-mingw-ucrt", exit: 7},
      {name: "success_without_output", origin: "x64-mingw-ucrt", mode: "no-output"},
      {name: "missing_command", origin: "x64-mingw-ucrt", missing: true},
      {name: "native_false", origin: false},
      {name: "native_nil", origin: nil},
      {name: "undefined_cross", origin: :undefined},
      {name: "linux_host", origin: "x86_64-linux-gnu"},
      {name: "boolean_cross", origin: true},
      {name: "string_spoof_object", origin: :spoof},
      {name: "non_boundary_mingw", origin: "x64-notmingw-ucrt"},
      {name: "native_exe_legacy", origin: false, suffix: ".exe", mode: "executable", legacy: true},
      {name: "linux_exe_legacy", origin: "x86_64-linux-gnu", suffix: ".exe", mode: "executable", legacy: true},
      {name: "failed_exe_legacy", origin: false, suffix: ".exe", mode: "executable", exit: 7},
      {name: "warning_is_error", origin: "x64-mingw-ucrt", mode: "warning", werror: true},
      {name: "universal_mingw", origin: "x64-mingw-ucrt", patched: true, universal: true}
    ]
    results = []
    cases.each do |test|
      case_work = File.join(work, test.fetch(:name))
      FileUtils.mkdir_p(case_work)
      Dir.chdir(case_work) do
        Object.send(:remove_const, :CROSS_COMPILING) if Object.const_defined?(:CROSS_COMPILING, false)
        origin = test[:origin]
        if origin == :spoof
          origin = Object.new
          def origin.to_s; "x64-mingw-ucrt"; end
        end
        Object.const_set(:CROSS_COMPILING, origin) unless origin == :undefined
        # Test-only bootstrap bypass: try_do itself remains real, while this
        # cached value prevents its preliminary have_devel? from compiling.
        $have_devel = true
        $EXEEXT = test.fetch(:suffix, "")
        $universal = test.fetch(:universal, false)
        ENV["TMPDIR"] = case_work
        output = MakeMakefile::CONFTEST + $EXEEXT
        command = if test[:missing]
                    [File.join(case_work, "missing-host-helper.exe")]
                  else
                    [host_ruby, "--disable-gems", helper, output, test.fetch(:mode, "regular"), test.fetch(:exit, 0).to_s]
                  end
        probe.define_singleton_method(:link_command) { |*_args| command }
        MakeMakefile::Logging.logfile(File.join(case_work, "mkmf.log"))
        expected = test[:legacy] || (variant == "new" && test[:patched]) || false
        options = test[:werror] ? {werror: true} : {}
        raw = probe.send(:try_link0, "int main(void) { return 0; }", **options)
        check(raw == (expected ? output : nil), "#{variant}/#{test[:name]} try_link0 returned #{raw.inspect}")
        check(!File.exist?(MakeMakefile::CONFTEST + ".c"), "#{test[:name]} left its C source fixture behind")
        if !test[:missing] && test[:mode] != "no-output"
          check(File.file?(output), "#{test[:name]} helper did not create its regular output file")
          check(File.binread(output).start_with?("\x7fELF".b) && File.size(output) == 64, "#{test[:name]} output is not the opaque ELF fixture")
          check(File.executable?(output) == (test[:mode] == "executable"), "#{test[:name]} did not exercise the intended host executable? predicate")
        end
        # A failed link must remain false even with a stale output present.
        result = probe.send(:try_link, "int main(void) { return 0; }", **options)
        check(result.equal?(expected), "#{variant}/#{test[:name]} try_link returned #{result.inspect}, expected #{expected}")
        check(!File.exist?(output), "#{test[:name]} public try_link did not remove accepted output") if expected
        check(ENV["TMPDIR"] == case_work, "#{test[:name]} did not restore TMPDIR")
        MakeMakefile::Logging.log_close
        results << {name: test[:name], expected: expected, try_link0: raw, try_link: result}
      end
    end
    report = {variant: variant, checks: @checks, cases: results, host_platform: RUBY_PLATFORM, mkmf_source: source, compiler_invoked: false, target_fixture_executed: false}
    File.write(report_path, JSON.pretty_generate(report) + "\n")
    puts "PASS: #{variant} mkmf, #{@checks} assertions"
  end

  def self.run(source = nil)
    @checks = 0
    started = Time.now
    base = File.join(ROOT, "temp/host-checks/windows-native-mkmf")
    work = File.join(base, "#{started.getutc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}")
    check(work.start_with?(File.join(ROOT, "temp") + File::SEPARATOR), "fixture path escaped temp")
    FileUtils.mkdir_p(work)
    patch = File.join(ROOT, "scripts/android/patches/ruby-3.4.10-mkmf-windows-cross.patch")
    source = File.expand_path(source || File.join(ROOT, "temp/windows-native/sources/ruby-3.4.10/lib/mkmf.rb"))
    check(Digest::SHA256.file(patch).hexdigest == PATCH_SHA, "canonical patch checksum differs")
    bytes = File.binread(source)
    input_sha = Digest::SHA256.hexdigest(bytes)
    check([BEFORE_SHA, AFTER_SHA].include?(input_sha), "mkmf source is neither pinned old nor pinned new version")
    repository = File.join(work, "patch-repository")
    git("init", "--quiet", repository)
    git_dir = File.join(repository, ".git")
    git("--git-dir=#{git_dir}", "config", "core.autocrlf", "false")
    fixtures = {}
    %w[old new].each do |variant|
      fixture = File.join(work, variant)
      FileUtils.mkdir_p(File.join(fixture, "lib"))
      # Always construct new from the verified old fixture, so a patched input
      # exercises both reverse and forward application without touching input.
      fixture_bytes = variant == "new" ? File.binread(fixtures.fetch("old")) : bytes
      File.binwrite(File.join(fixture, "lib/mkmf.rb"), fixture_bytes)
      args = ["-C", fixture, "--git-dir=#{git_dir}", "--work-tree=#{fixture}", "apply"]
      if variant == "old" && input_sha == AFTER_SHA
        git(*args, "--reverse", "--check", patch)
        git(*args, "--reverse", patch)
      elsif variant == "new"
        git(*args, "--check", patch)
        git(*args, patch)
      end
      git(*args, *(variant == "new" ? ["--reverse", "--check"] : ["--check"]), patch)
      fixtures[variant] = File.join(fixture, "lib/mkmf.rb")
      check(Digest::SHA256.file(fixtures[variant]).hexdigest == (variant == "old" ? BEFORE_SHA : AFTER_SHA), "#{variant} fixture checksum differs")
    end
    reports = %w[old new].map do |variant|
      report_path = File.join(work, "#{variant}-report.json")
      command = [RbConfig.ruby, "--disable-gems", File.expand_path(__FILE__), "--worker", fixtures.fetch(variant), File.join(work, "#{variant}-cases"), report_path, variant, RbConfig.ruby]
      stdout, stderr, status = Open3.capture3(*command)
      File.write(File.join(work, "#{variant}-stdout.log"), stdout)
      File.write(File.join(work, "#{variant}-stderr.log"), stderr)
      check(status.success?, "#{variant} worker failed:\n#{stdout}\n#{stderr}")
      JSON.parse(File.read(report_path))
    end
    check(Digest::SHA256.file(source).hexdigest == input_sha, "input source changed during host test")
    total = @checks + reports.sum { |report| report.fetch("checks") }
    result = {success: true, checks: total, driver_checks: @checks, started: started.iso8601, finished: Time.now.iso8601, input_source: source, input_source_sha256: input_sha, patch_sha256: PATCH_SHA, host_ruby: RbConfig.ruby, host_platform: RUBY_PLATFORM, compiler_invoked: false, target_fixture_executed: false, reports: reports, evidence_directory: work}
    File.write(File.join(work, "report.json"), JSON.pretty_generate(result) + "\n")
    File.write(File.join(base, "latest.json"), JSON.pretty_generate(result) + "\n")
    puts "PASS: #{total} Windows cross-mkmf host assertions (real old/new mkmf; no compiler or target execution)"
    puts "Evidence: #{work}"
  end
end

case ARGV.shift
when "--worker"
  WindowsNativeMkmfTest.worker(*ARGV)
when "--source"
  raise "usage: windows_native_mkmf_test.rb [--source pinned-mkmf.rb]" unless ARGV.length == 1
  WindowsNativeMkmfTest.run(ARGV.first)
when nil
  WindowsNativeMkmfTest.run
else
  raise "usage: windows_native_mkmf_test.rb [--source pinned-mkmf.rb]"
end
