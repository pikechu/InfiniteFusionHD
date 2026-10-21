# Independent regression for account/server bindings, credential restoration and
# read-only replay failures. Uses real Client/Profile and isolated profile files.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
class PokeBattle_Battle; end unless defined?(PokeBattle_Battle)
load "Data/Scripts/054_Multiplayer/005_Gym.rb"
load "Data/Scripts/054_Multiplayer/006_Trade.rb"
load "Data/Scripts/054_Multiplayer/009_Pool.rb"
load "Data/Scripts/054_Multiplayer/010_Collections.rb"
require "fileutils"
directory = File.join(root, "temp", "multiplayer", "identity-regression", "run-#{Process.pid}-#{Time.now.to_i}")
FileUtils.mkdir_p(directory)
original_server_environment = ENV["KIF_MULTIPLAYER_SERVER"]
ENV.delete("KIF_MULTIPLAYER_SERVER")
OWNER_A = "p_" + "a" * 24
OWNER_B = "p_" + "b" * 24
SERVER_A = "http://192.168.1.10:8765"
SERVER_B = "http://127.0.0.1:8765"
SERVER_C = "http://192.168.1.20:8765"
class IdentityRecoveryTransport
  attr_reader :calls
  attr_accessor :download_body, :download_failure
  def initialize; @calls = []; @download_body = '{broken'; end
  def call(method, url, body, token, _timeout)
    @calls << { :method => method, :url => url, :body => KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(body)), :token => token }
    if url.end_with?("/v1/identities/recover")
      target = { "code_a" => OWNER_A, "code_b" => OWNER_B }[body["recovery_code"]]
      unless target && (!body["expected_identity_id"] || body["expected_identity_id"] == target)
        return response(403, { "ok" => false, "error" => { "code" => "identity_switch_pending", "message" => "recovery target differs from saved owner" } })
      end
      return response(200, { "ok" => true, "identity" => { "id" => target, "nickname" => "Recovered" }, "token" => "test_token_#{target}", "recovery_code" => body["recovery_code"] })
    elsif url.include?("/v1/operations/")
      return response(404, { "ok" => false, "error" => { "code" => "operation_not_found", "message" => "read-only operation is not cached" } })
    elsif url.end_with?("/download")
      raise IOError, "injected read transport failure" if @download_failure
      return { :status => 200, :body => @download_body }
    elsif url.end_with?("/v1/rooms")
      return response(201, { "ok" => true, "room" => { "code" => "ABCDEF" } })
    end
    response(200, { "ok" => true })
  end
  def response(status, value); { :status => status, :body => KIFMultiplayer::WireJSON.dump(value) }; end
end

checks = 0
log = File.open(File.join(directory, "identity-recovery-test.log"), "w")
assert = lambda do |condition, description|
  raise "FAIL #{description}" unless condition
  checks += 1; log.puts("PASS #{description}"); log.flush
end
reject = lambda do |description, &action|
  rejected = false
  begin
    action.call
  rescue KIFMultiplayer::Error
    rejected = true
  end
  assert.call(rejected, description)
end
profile_number = 0
make = lambda do |server = SERVER_A|
  profile_number += 1
  $Trainer = Object.new
  profile = KIFMultiplayer::Profile.new(File.join(directory, "profile-#{profile_number}.json"))
  profile.data["server"] = server
  profile.save
  transport = IdentityRecoveryTransport.new
  [profile, transport, KIFMultiplayer::Client.new(profile, transport)]
end
escrow = lambda do |server = SERVER_A, owner = OWNER_A|
  $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, { "server" => server, "player_id" => owner, "kind" => "pool", "entries" => [] })
end
begin
  profile, transport, client = make.call
  escrow.call
  before_escrow = Marshal.dump($Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow))
  assert.call(KIFMultiplayer.bound_identity_id(profile) == OWNER_A, "empty profile finds trusted saved escrow owner")
  client.recover_identity("code_a")
  assert.call(client.player_id == OWNER_A && transport.calls.last[:body]["expected_identity_id"] == OWNER_A, "empty profile recovers only the saved original identity")
  assert.call(Marshal.dump($Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow)) == before_escrow, "credential recovery never modifies locked original escrow")
  reject.call("unrelated recovery code rejected while escrow pending") { client.recover_identity("code_b") }
  assert.call(client.player_id == OWNER_A, "rejected credential recovery retains original identity")
  profile, transport, client = make.call
  profile.account["identity"] = { "id" => OWNER_B }
  profile.account["token"] = "wrong_new_identity_token"
  escrow.call
  client.recover_identity("code_a")
  assert.call(client.player_id == OWNER_A && transport.calls.last[:body]["expected_identity_id"] == OWNER_A, "accidentally created new account cannot block recovery of bound escrow owner")
  profile, transport, client = make.call(SERVER_B)
  escrow.call
  reject.call("wrong server cannot replace original binding with an unrelated URL") { profile.server = SERVER_C }
  profile.server = SERVER_A
  assert.call(profile.server == SERVER_A, "wrong default server can return to the sole saved original server")
  client.recover_identity("code_a")
  assert.call(client.player_id == OWNER_A, "returning to original server enables exact recovery code restoration")
  reject.call("recovered escrow cannot be taken to arbitrary new server") { profile.server = SERVER_C }
  profile, transport, client = make.call(SERVER_B)
  escrow.call
  profile.data["servers"][SERVER_B] = { "pending" => { "identity_id" => OWNER_B, "body" => { "request_id" => "other_server_operation" } } }
  reject.call("original-server shortcut refuses conflicting operation on another server") { profile.server = SERVER_A }
  profile.data["servers"][SERVER_B].delete("pending")
  profile.server = SERVER_A
  assert.call(profile.server == SERVER_A, "cleared conflicting server operation permits original-server restoration")
  profile, transport, client = make.call(SERVER_A)
  escrow.call
  profile.account["pending"] = { "identity_id" => OWNER_B, "path" => "/v1/rooms", "method" => "POST", "body" => { "request_id" => "conflicting_owner_operation" } }
  reject.call("different pending and escrow owners cannot rotate credentials") { client.recover_identity("code_a") }
  assert.call(transport.calls.empty?, "multi-owner conflict is rejected before any credential request")
  profile, transport, client = make.call
  profile.account["gym_session"] = { "owner_id" => OWNER_A, "id" => "gc_test" }
  profile.account["trade_pending"] = { "player_id" => OWNER_B }
  reject.call("gym and local trade owner conflict blocks restoration") { KIFMultiplayer.bound_identity_id(profile) }
  profile.account.delete("trade_pending")
  client.recover_identity("code_a")
  assert.call(client.player_id == OWNER_A, "gym journal binds recovery even without current credentials")
  profile, transport, client = make.call
  profile.account["identity"] = { "id" => OWNER_B }
  profile.account["pending"] = { "identity_id" => OWNER_A, "path" => "/v1/rooms", "method" => "POST", "body" => { "request_id" => "original_operation" } }
  reject.call("saved operation cannot replay under a different current identity") { client.recover_pending }
  assert.call(transport.calls.empty?, "cross-identity replay never reaches transport")
  client.recover_identity("code_a")
  client.recover_pending
  assert.call(profile.account["pending"].nil? && transport.calls.last[:token] == "test_token_#{OWNER_A}", "restoring owner safely replays original pending request with recovered credentials")
  profile, transport, client = make.call(SERVER_B)
  escrow.call
  profile.save
  ENV["KIF_MULTIPLAYER_SERVER"] = SERVER_A
  loaded = KIFMultiplayer::Profile.new(profile.path)
  assert.call(loaded.server == SERVER_A && KIFMultiplayer.bound_identity_id(loaded) == OWNER_A, "environment override can restore the unique bound original server")
  ENV["KIF_MULTIPLAYER_SERVER"] = SERVER_C
  reject.call("environment override cannot move saved escrow to an unrelated server") { KIFMultiplayer::Profile.new(profile.path) }
  ENV.delete("KIF_MULTIPLAYER_SERVER")
  profile, transport, client = make.call
  profile.account["identity"] = { "id" => OWNER_A }
  profile.account["token"] = "test_token"
  download_path = "/v1/replays/replay_readonly/download"
  reject.call("malformed replay download is rejected safely") { client.request("POST", download_path, { "compatibility" => {} }) }
  assert.call(profile.account["pending"].nil?, "read-only malformed replay response cannot lock later mutations")
  assert.call(transport.calls.last[:body]["request_id"].is_a?(String), "read-only POST still supplies protocol request ID")
  client.request("POST", "/v1/rooms", { "name" => "after read failure" })
  assert.call(profile.account["pending"].nil? && transport.calls.last[:url].end_with?("/v1/rooms"), "later business mutation remains usable after replay parse failure")
  transport.download_body = KIFMultiplayer::WireJSON.dump({ "ok" => true, "nodes" => Array.new(KIFMultiplayer::WireJSON::MAX_NODES + 1, nil) })
  reject.call("node-limit replay rejected without durable operation") { client.request("POST", download_path, { "compatibility" => {} }) }
  assert.call(profile.account["pending"].nil?, "oversized node count does not create a permanent pending operation")
  transport.download_failure = true
  reject.call("read-only transport failure remains recoverable as a fresh read") { client.request("POST", download_path, { "compatibility" => {} }) }
  assert.call(profile.account["pending"].nil?, "read-only timeout creates no business journal")
  economic_pending = { "identity_id" => OWNER_A, "method" => "POST", "path" => "/v1/rooms", "body" => { "request_id" => "economic_operation", "name" => "must preserve" } }
  profile.account["pending"] = economic_pending
  before_read_calls = transport.calls.length
  reject.call("read-only failure remains independent of an economic pending operation") { client.request("POST", download_path, { "compatibility" => {} }) }
  assert.call(profile.account["pending"] == economic_pending && transport.calls.drop(before_read_calls).all? { |call| call[:url].end_with?("/download") }, "readonly download neither discards nor replays unrelated business operation")
  client.recover_pending
  assert.call(profile.account["pending"].nil? && transport.calls.last[:url].end_with?("/v1/rooms"), "explicit recovery still executes the preserved business operation")
  # Migrate journals left by older clients that treated download as a mutation.
  profile.account["pending"] = { "identity_id" => OWNER_A, "method" => "POST", "path" => download_path,
    "body" => { "request_id" => "legacy_download", "compatibility" => {} } }
  transport.download_failure = false
  transport.download_body = '{still_invalid'
  assert.call(client.recover_pending.nil?, "legacy replay journal safely drops without repeating an unreadable download")
  assert.call(profile.account["pending"].nil?, "old read-only download journal is removed even when replay remains unreadable")
  assert.call(KIFMultiplayer::Profile.new(profile.path).account["pending"].nil?, "read-only journal migration persists across process restart")
  # UI polling regression: successful retry of an unchanged room must clear the
  # transient offline text; cancelling during an HTTP wait restores callbacks.
  load "Data/Scripts/054_Multiplayer/002_UI.rb"
  $identity_ui_test = { :frames => 0, :polls => 0, :windows => [], :back => false }
  class IdentityUIWindow
    attr_accessor :index, :z
    attr_reader :text, :history
    def initialize(_commands = nil)
      @index, @disposed, @history = 0, false, []
      $identity_ui_test[:windows] << self
    end
    def text=(value); @text = value; @history << value; end
    def update; end
    def resizeToFit(_choices); end
    def dispose; @disposed = true; end
    def disposed?; @disposed; end
  end
  Window_CommandPokemonEx = Class.new(IdentityUIWindow)
  module Graphics
    def self.update
      $identity_ui_test[:frames] += 1
      raise "room UI did not terminate" if $identity_ui_test[:frames] > 12
    end
  end
  module Input
    BACK = 1
    USE = 2
    def self.update; end
    def self.trigger?(key)
      return $identity_ui_test[:back] if key == BACK
      key == USE && $identity_ui_test[:polls] >= 2 && $identity_ui_test[:windows].first.text == $identity_ui_test[:heading]
    end
  end
  Object.send(:define_method, :pbCreateMessageWindow) { IdentityUIWindow.new }
  Object.send(:define_method, :pbPositionNearMsgWindow) { |_window, _message, _side| nil }
  Object.send(:define_method, :pbDisposeMessageWindow) { |message| message.dispose }
  class IdentityRoomClient
    attr_accessor :wait_update, :room, :cancel_on_request
    def request(_method, _path)
      $identity_ui_test[:polls] += 1
      if @cancel_on_request
        $identity_ui_test[:back] = true
        @wait_update.call
      end
      raise KIFMultiplayer::Error.new("test connection lost", "unreachable") if $identity_ui_test[:polls] == 1
      { "room" => @room }
    end
  end
  room = { "code" => "AABBCC", "name" => "Unchanged room", "status" => "configuring", "mode" => "friendly_singles", "members" => [] }
  room_client = IdentityRoomClient.new
  room_client.room = room
  previous_callback = proc {}
  room_client.wait_update = previous_callback
  room_ui = KIFMultiplayer::UI.new(room_client)
  $identity_ui_test[:heading] = room_ui.room_summary(room)
  original_now = Time.method(:now)
  Time.define_singleton_method(:now) { original_now.call + $identity_ui_test[:frames] }
  begin
    result = room_ui.live_room_choice(room, Array.new(8, "choice"))
    message = $identity_ui_test[:windows].first
    assert.call(result[0] == 0 && $identity_ui_test[:polls] == 2, "live room retries one transient network failure")
    assert.call(message.history.any? { |value| value.include?("连接暂时中断") } && message.text == $identity_ui_test[:heading], "unchanged successful room response clears stale offline warning")
    assert.call(room_client.wait_update.equal?(previous_callback) && $identity_ui_test[:windows].all?(&:disposed?), "room selection restores callback and disposes both windows")
    $identity_ui_test = { :frames => 0, :polls => 0, :windows => [], :back => false }
    room_client.cancel_on_request = true
    result = room_ui.live_room_choice(room, Array.new(8, "choice"))
    assert.call(result[0] == 6 && $identity_ui_test[:polls] == 1, "back input during a network wait closes room UI immediately")
    assert.call(room_client.wait_update.equal?(previous_callback) && $identity_ui_test[:windows].all?(&:disposed?), "cancelled room wait restores callback and releases windows")
  ensure
    Time.define_singleton_method(:now, original_now)
  end
  module Font
    class << self; attr_accessor :default_name; end
    def self.exist?(name); name == "Noto Sans SC"; end
  end
  module MessageConfig
    class << self
      attr_accessor :test_system, :test_small, :test_narrow
      def pbGetSystemFontName; @test_system; end
      def pbGetSmallFontName; @test_small; end
      def pbGetNarrowFontName; @test_narrow; end
      def pbSetSystemFontName(value); @test_system = value; end
      def pbSetSmallFontName(value); @test_small = value; end
      def pbSetNarrowFontName(value); @test_narrow = value; end
    end
  end
  Font.default_name = ["Old font"]
  MessageConfig.test_system, MessageConfig.test_small, MessageConfig.test_narrow = "Old main", "Old small", "Old narrow"
  IdentityUISystem = Struct.new(:download_sprites, :shinyadvanced)
  $PokemonSystem = IdentityUISystem.new(0, 1)
  original_system_bytes = Marshal.dump($PokemonSystem)
  reject.call("font scope propagates UI error after cleanup") do
    KIFMultiplayer.with_ui_fonts do
      assert.call(Font.default_name == "Noto Sans SC" && MessageConfig.pbGetSystemFontName == "Noto Sans SC", "multiplayer UI uses CJK font inside scope")
      assert.call($PokemonSystem.download_sprites == 1, "multiplayer scope disables unsafe native asset downloads")
      assert.call($PokemonSystem.shinyadvanced == 2, "online UI preserves all validated advanced shiny channels")
      assert.call(Marshal.dump($PokemonSystem) == original_system_bytes, "online presentation never changes settings serialized by a transaction save")
      KIFMultiplayer.with_ui_fonts { assert.call($PokemonSystem.download_sprites == 1 && $PokemonSystem.shinyadvanced == 2, "nested presentation scope retains safe getters") }
      assert.call($PokemonSystem.download_sprites == 1 && $PokemonSystem.shinyadvanced == 2, "nested scope restores enclosing presentation state")
      background_values = Thread.new { [$PokemonSystem.download_sprites, $PokemonSystem.shinyadvanced] }.value
      assert.call(background_values == [0, 1], "temporary presentation does not alter background thread settings")
      raise KIFMultiplayer::Error, "injected UI failure"
    end
  end
  assert.call(Font.default_name == ["Old font"] && MessageConfig.pbGetSystemFontName == "Old main" && MessageConfig.pbGetSmallFontName == "Old small" && MessageConfig.pbGetNarrowFontName == "Old narrow", "font scope restores every single-player font after an exception")
  assert.call($PokemonSystem.download_sprites == 0, "online UI error restores original single-player download preference")
  assert.call($PokemonSystem.shinyadvanced == 1, "online UI error restores original single-player color mode")
  Font.define_singleton_method(:exist?) { |_name| false }
  KIFMultiplayer.with_ui_fonts { assert.call($PokemonSystem.download_sprites == 1 && $PokemonSystem.shinyadvanced == 2, "download/color guard also applies without the optional CJK font") }
  assert.call($PokemonSystem.download_sprites == 0 && $PokemonSystem.shinyadvanced == 1, "font-free scope restores download/color preferences")
  log.puts("IDENTITY_RECOVERY_TEST_PASS checks=#{checks}")
  puts("IDENTITY_RECOVERY_TEST_PASS checks=#{checks} evidence=#{directory}")
rescue StandardError => error
  log.puts("IDENTITY_RECOVERY_TEST_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  raise
ensure
  ENV["KIF_MULTIPLAYER_SERVER"] = original_server_environment
  log.close
end
