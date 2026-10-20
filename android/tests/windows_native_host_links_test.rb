require 'fileutils'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
base = File.join(root, 'temp/host-checks/host-links')
FileUtils.mkdir_p(base)
work = Dir.mktmpdir('aliases-', base)
scope = File.join(work, 'build')
FileUtils.mkdir_p(File.join(scope, 'logs'))
ENV['KIF_RUBY_WINDOWS_BUILD_ROOT'] = scope
Object.send(:remove_const, :CROSS_COMPILING) if Object.const_defined?(:CROSS_COMPILING, false)
Object.const_set(:CROSS_COMPILING, 'x64-mingw-ucrt')
# Simulate the exact observed Windows permission failure without requesting any
# symlink privilege or depending on this machine's Developer Mode setting.
File.singleton_class.prepend(Module.new do
  def symlink(*_args)
    raise Errno::EACCES, 'expected host fixture denial'
  end
end)
load File.join(root, 'scripts/android/windows-native-ruby-host-links.rb')
checks = 0
assert = proc { |value, message| raise message unless value; checks += 1 }
denied = proc do |&block|
  begin
    block.call
    false
  rescue Errno::EACCES, Errno::EPERM, Errno::ENOENT
    true
  end
end
source = File.join(scope, 'libruby.so.3.4.10')
alias_path = File.join(scope, 'libruby.so')
File.binwrite(source, "\x7fELF-alias-fixture".b)
assert.call(File.symlink('libruby.so.3.4.10', alias_path) == 0, 'copy fallback failed')
assert.call(File.binread(alias_path) == File.binread(source), 'alias data differs')
assert.call(!File.symlink?(alias_path), 'expected a portable regular-file alias')
assert.call(File.read(File.join(scope, 'logs/ruby-host-link-copies.log')).include?('libruby.so'), 'audit missing')
assert.call($LOADED_FEATURES.include?('rubygems/defaults/operating_system.rb'), 'host OS RubyGems defaults were not isolated')
outside = File.join(work, 'outside.so')
File.binwrite(outside, 'outside')
assert.call(denied.call { File.symlink(outside, File.join(scope, 'bad-source.so')) }, 'outside source accepted')
assert.call(!File.exist?(File.join(scope, 'bad-source.so')), 'outside-source alias created')
assert.call(denied.call { File.symlink(source, File.join(work, 'bad-destination.so')) }, 'outside destination accepted')
assert.call(denied.call { File.symlink(scope, File.join(scope, 'directory-alias')) }, 'directory copied')
assert.call(denied.call { File.symlink('missing.so', File.join(scope, 'missing-alias.so')) }, 'missing source accepted')
invalid_alias = File.join(scope, 'bad-drive-alias')
begin
  File.symlink('ext/bigdecimal/D:/missing/lib', invalid_alias)
  raise 'invalid drive-shaped alias accepted'
rescue Errno::EACCES => error
  assert.call(error.message.include?('expected host fixture denial'), 'normalization replaced the original permission failure')
end
assert.call(!File.exist?(invalid_alias), 'invalid drive-shaped alias created')
File.binwrite(alias_path, 'preserve-existing')
begin
  File.symlink('libruby.so.3.4.10', alias_path)
  raise 'existing alias overwritten'
rescue Errno::EEXIST
  checks += 1
end
assert.call(File.binread(alias_path) == 'preserve-existing', 'existing alias changed')
puts "PASS: #{checks} host alias assertions; no compiler/target execution; evidence #{work}"
