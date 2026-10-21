load File.expand_path("battle_test.rb", __dir__)
module Graphics
  def self.update; end
end
module Input
  USE = 1
  BACK = 2
  def self.update; end
  def self.trigger?(_button); false; end
end
class ConfirmationMessage < FakeDisposable
  attr_accessor :letterbyletter, :text
  def update; end
end
class Window_CommandPokemonEx < FakeDisposable
  attr_accessor :z
  attr_reader :commands
  def initialize(commands); @commands = commands; $confirmation_commands = self; end
  def resizeToFit(*); end
  def update; end
  def index; 0; end
end
def _INTL(value); value; end
def pbCreateMessageWindow; $confirmation_message = ConfirmationMessage.new; end
def pbPositionNearMsgWindow(*); end
session = Object.new
client = FakeClient.new([])
session.define_singleton_method(:client) { client }
def session.native_presenter?; false; end
def session.heartbeat; raise KIFMultiplayer::ServerTerminal; end
$game_temp.message_window_showing = true
assert_raises(KIFMultiplayer::ServerTerminal, "Confirmation swallowed server termination") do
  KIFMultiplayer.battle_confirm("Confirm surrender", session)
end
assert($confirmation_commands.disposed? && $confirmation_message.disposed?, "Terminal heartbeat leaked confirmation message/command windows")
assert($game_temp.message_window_showing == true, "Nested confirmation changed the original message-window flag")
puts "BATTLE_CONFIRMATION_PASS checks=#{$checks}"
