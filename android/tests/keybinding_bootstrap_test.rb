# Exercise the actual game bootstrap method without creating a scene or using SDL.
require "tmpdir"
require "fileutils"

module System
  class << self
    attr_accessor :android_host, :save_directory
    def is_android?; !!@android_host; end
    def data_directory; @save_directory; end
  end
end
class SpriteWrapper; end
class Color
  def initialize(*_args); end
end
class File
  class << self
    attr_reader :test_copy_calls
    def copy(source, destination)
      (@test_copy_calls ||= []) << [source, destination]
      FileUtils.copy_file(source, destination)
    end
  end
end

root = File.expand_path("../..", __dir__)
System.android_host = false
load File.join(root, "Data/Scripts/000_Platform.rb")
load File.join(root, "Data/Scripts/016_UI/013_UI_Load.rb")
screen = PokemonLoadScreen.allocate # Do not discover or load any real player slot.
messages = []
screen.define_singleton_method(:print) { |message| messages << message }
checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end

FileUtils.mkdir_p(File.join(root, "temp"))
Dir.mktmpdir("kif-keybinding-bootstrap-", File.join(root, "temp")) do |work|
  Dir.chdir(work) do
    FileUtils.mkdir_p(["Data", "android-saves", "desktop-saves"])
    File.binwrite("Data/keybindings.mkxp1", "fixture desktop profile")
    System.android_host = true
    System.save_directory = File.join(work, "android-saves") + "/"
    android_path = System.save_directory + "keybindings.mkxp1"
    assert.call(!KIF::Platform.desktop_keybinding_bootstrap?, "Android exposed desktop profile bootstrap")
    screen.copyKeybindings
    assert.call(!File.exist?(android_path) && (File.test_copy_calls || []).empty?, "Android copied desktop controls into save storage")
    assert.call(messages.empty?, "Android displayed desktop restart prompt")
    File.binwrite(android_path, "existing Android-side file")
    screen.copyKeybindings
    assert.call(File.binread(android_path) == "existing Android-side file", "Android altered an existing profile file")

    System.android_host = false
    System.save_directory = File.join(work, "desktop-saves") + "/"
    desktop_path = System.save_directory + "keybindings.mkxp1"
    assert.call(KIF::Platform.desktop_keybinding_bootstrap?, "Windows lost desktop profile bootstrap")
    screen.copyKeybindings
    assert.call(File.binread(desktop_path) == "fixture desktop profile" && File.test_copy_calls.length == 1, "Windows no longer copies its missing default profile")
    assert.call(messages.length == 1 && messages.first.include?("Please re-launch"), "Windows restart notification changed")
    File.binwrite(desktop_path, "player desktop bindings")
    screen.copyKeybindings
    assert.call(File.binread(desktop_path) == "player desktop bindings", "Windows overwrote player bindings")
    assert.call(File.test_copy_calls.length == 1 && messages.length == 1, "Windows repeat launch copied/prompted again")
  end
end
puts "PASS: #{checks} desktop keybinding bootstrap assertions (actual game method; mocked scene/native host)"
