# Host-only regression. Android aliases are modeled at File.realpath's boundary;
# actual Android symlink resolution remains covered by the device rerun.
require 'tmpdir'
require 'fileutils'

root = File.expand_path('../..', __dir__)
fixture = File.read(File.join(__dir__, 'native-ruby-probe.rb'), encoding: 'UTF-8').gsub("\r\n", "\n")
guard = fixture.split("# KIF_NATIVE_PROBE_STORAGE_GUARD_BEGIN\n", 2).last
guard = guard.split("# KIF_NATIVE_PROBE_STORAGE_GUARD_END", 2).first
raise 'storage guard fixture markers missing' unless guard.include?('module KIFNativeProbeStorage')
eval(guard, TOPLEVEL_BINDING, 'native-ruby-probe.rb guard')

work = File.join(root, 'temp/native-probe/host-storage-guard')
FileUtils.mkdir_p(File.join(work, 'app/files/native-probe/output'))
FileUtils.mkdir_p(File.join(work, 'other-app/files/native-probe/output'))
files = File.join(work, 'app/files')
output = File.join(files, 'native-probe/output')
raise 'real private directory rejected' unless KIFNativeProbeStorage.output_directory(files, output) == File.realpath(output)
checks = 1

original = File.method(:realpath)
canonical = '/data/user/0/org.kuray.kif.nativeprobe/files'
aliases = {
  '/data/data/org.kuray.kif.nativeprobe/files' => canonical,
  canonical => canonical,
  '/data/data/org.kuray.kif.nativeprobe/files/native-probe/output' => canonical + '/native-probe/output',
  canonical + '/native-probe/output' => canonical + '/native-probe/output',
  '/data/data/org.kuray.kif.nativeprobe/files/native-probe/escape' => '/data/user/0/org.kuray.kif/files/saves'
}
File.define_singleton_method(:realpath) { |path, *args| aliases.fetch(path) { original.call(path, *args) } }
begin
  [['/data/data/org.kuray.kif.nativeprobe/files', canonical + '/native-probe/output'],
   [canonical, '/data/data/org.kuray.kif.nativeprobe/files/native-probe/output']].each do |supplied_files, supplied_output|
    raise 'same-app alias rejected' unless KIFNativeProbeStorage.output_directory(supplied_files, supplied_output) == canonical + '/native-probe/output'
    checks += 1
  end
  ['../saves', 'native-probe-other/output', 'native-probe', '../other-app/files/native-probe/output'].each do |relative|
    path = File.expand_path(relative, files)
    FileUtils.mkdir_p(path)
    begin
      KIFNativeProbeStorage.output_directory(files, path)
      raise 'outside/boundary-spoofed path accepted'
    rescue RuntimeError => error
      raise unless error.message == 'Probe output escaped application private files'
      checks += 1
    end
  end
  begin
    KIFNativeProbeStorage.output_directory('/data/data/org.kuray.kif.nativeprobe/files', '/data/data/org.kuray.kif.nativeprobe/files/native-probe/escape')
    raise 'cross-application symlink escape accepted'
  rescue RuntimeError => error
    raise unless error.message == 'Probe output escaped application private files'
    checks += 1
  end
ensure
  File.define_singleton_method(:realpath, original)
end
STDOUT.puts "PASS: #{checks} host-only private storage guard checks; Android aliases modeled, no target/device execution"
