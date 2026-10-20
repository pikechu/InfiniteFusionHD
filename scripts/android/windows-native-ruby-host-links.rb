# Host-build helper only; never loaded by the Android game/runtime.
# Native Windows Ruby cannot always create the aliases requested by rbinstall.
module KIFRubyHostLinks
  def symlink(source, destination)
    super
  rescue Errno::EACCES, Errno::EPERM, NotImplementedError => original_error
    # Symlink targets are relative to the destination directory, not cwd.
    begin
      destination = File.expand_path(destination)
      source = File.realpath(File.expand_path(source, File.dirname(destination)))
      parent = File.realpath(File.dirname(destination))
    rescue Errno::EINVAL, Errno::ENOENT, Errno::ENOTDIR
      # tool/ln_sr.rb has its own directory-copy fallback for permission
      # failures. A target fake.rb can misclassify a Windows drive path;
      # preserve the original failure so that fallback can use its original
      # source argument. Do not copy an invalid or unresolved alias ourselves.
      raise original_error
    end
    within = proc { |path| path.tr('\\', '/').downcase.start_with?(ROOT.downcase + '/') }
    raise original_error unless within.call(source) && within.call(parent + '/') && File.file?(source)
    created = false
    begin
      # Preserve an existing path even if a caller unexpectedly skipped unlink.
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, File.stat(source).mode & 0o777) do |output|
        created = true
        IO.copy_stream(source, output)
      end
      File.open(File.join(ROOT, 'logs/ruby-host-link-copies.log'), 'a') do |log|
        log.puts "#{source}\t#{destination}"
      end
      0
    rescue Exception
      File.unlink(destination) if created && File.file?(destination)
      raise
    end
  end
end

host = defined?(CROSS_COMPILING) && CROSS_COMPILING.is_a?(String) ? CROSS_COMPILING : RUBY_PLATFORM
root = ENV['KIF_RUBY_WINDOWS_BUILD_ROOT']
if /(?:\A|-)(?:mswin|mingw)/.match?(host) && root && !root.empty?
  KIFRubyHostLinks.const_set(:ROOT, File.realpath(root).tr('\\', '/').sub(%r{/+\z}, '').freeze)
  File.singleton_class.prepend(KIFRubyHostLinks)
  # rbinstall loads the target RubyGems sources. Do not mix RubyInstaller's
  # Windows OS integration from the host load path into an Android fake.rb.
  feature = 'rubygems/defaults/operating_system.rb'
  $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
end
