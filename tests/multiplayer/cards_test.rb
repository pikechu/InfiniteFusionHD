previous_fixture_flag = ENV["KIF_TRADE_FIXTURES_ONLY"]
ENV["KIF_TRADE_FIXTURES_ONLY"] = "1"
load File.expand_path("trade_test.rb", __dir__)
ENV["KIF_TRADE_FIXTURES_ONLY"] = previous_fixture_flag
load "Data/Scripts/054_Multiplayer/013_Cards.rb"
module GameData
  class TrainerType
    def self.exists?(id); %w[POKEMONTRAINER_Red POKEMONTRAINER_Leaf].include?(id.to_s); end
    def self.front_sprite_filename(id)
      raise "Invalid trainer lookup" unless exists?(id)
      id.to_s == "POKEMONTRAINER_Red" ? "Graphics/Trainers/trainer000" : "Graphics/Trainers/trainer001"
    end
  end
end
KIFMultiplayer::Snapshot.define_singleton_method(:export) { |pokemon| KIFMultiplayer::TradeCodec.copy(validate(pokemon.snapshot["pokemon"])) }

class CardsTestService
  attr_reader :showcases, :versions
  attr_accessor :fail_publish
  def initialize
    @showcases, @cards, @operations, @counter, @versions = {}, {}, {}, 0, 0
  end
  def copy(value); KIFMultiplayer::TradeCodec.copy(value); end
  def card(owner)
    settings = @cards[owner] || { "avatar" => "POKEMONTRAINER_Red", "show_badges" => false, "showcases" => [] }
    active = settings["showcases"].filter_map { |code| value = @showcases[code]; value && value["active"] && value["owner_id"] == owner ? copy(value.reject { |key, _| key == "active" }) : nil }
    { "id" => owner, "nickname" => "Card #{owner}", "friend_code" => "%08X" % owner.split("_").last.to_i,
      "avatar" => settings["avatar"], "show_badges" => settings["show_badges"], "badges" => settings["show_badges"] ? [{ "id" => "boss:test", "kind" => "boss_medal", "boss_id" => "test_boss" }] : [],
      "showcases" => active, "showcase_codes" => active.map { |entry| entry["code"] }, "capacity" => 6 }
  end
  def request(owner, method, path, body)
    if path == "/v1/showcases" && method == "GET"
      return { "showcases" => @showcases.values.select { |value| value["owner_id"] == owner && value["active"] }.map { |value| copy(value.reject { |key, _| key == "active" }) } }
    elsif path == "/v1/showcases" && method == "POST"
      raise KIFMultiplayer::Error.new("Injected offline publish", "unreachable") if @fail_publish
      key = [owner, body["request_id"]]
      return copy(@operations[key]) if @operations[key]
      code = body["code"]
      old = @showcases[code]
      raise KIFMultiplayer::Error, "not owner" if old && old["owner_id"] != owner
      unless code
        @counter += 1
        code = "%08X" % (0xC0000000 + @counter)
      end
      value = { "code" => code, "owner_id" => owner, "version" => old ? old["version"] + 1 : 1,
        "snapshot" => KIFMultiplayer::CardData.public_snapshot(body["snapshot"], body["public_fields"]), "public_fields" => body["public_fields"].dup, "active" => true }
      @showcases[code] = value
      @versions += 1
      @operations[key] = { "showcase" => copy(value.reject { |field, _| field == "active" }) }
      return copy(@operations[key])
    elsif path.start_with?("/v1/showcases/")
      code = path.split("/")[3]
      value = @showcases[code]
      raise KIFMultiplayer::Error.new("not found", "showcase_not_found") unless value && value["active"]
      if method == "POST"
        raise KIFMultiplayer::Error, "not owner" unless value["owner_id"] == owner
        value["active"] = false
        return { "ok" => true }
      end
      return { "showcase" => copy(value.reject { |field, _| field == "active" }) }
    elsif path == "/v1/cards/me"
      if method == "POST"
        raise KIFMultiplayer::Error, "invalid source" unless (body.keys - %w[avatar show_badges showcases request_id]).empty?
        raise KIFMultiplayer::Error, "capacity" unless body["showcases"].length <= 6
        body["showcases"].each do |code|
          value = @showcases[code]
          raise KIFMultiplayer::Error, "invalid showcase" unless value && value["active"] && value["owner_id"] == owner
        end
        @cards[owner] = copy(body)
      end
      return { "card" => card(owner) }
    elsif path.start_with?("/v1/cards/")
      id = Integer(path.split("/").last, 16)
      return { "card" => card("player_#{id}") }
    end
    raise KIFMultiplayer::Error, "unknown cards test endpoint"
  end
end

checks = 0
log = File.open(File.join(TRADE_TEST_DIR, "cards-test.log"), "w")
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
begin
  service = CardsTestService.new
  clients = [TradeTestClient.new(service, 7), TradeTestClient.new(service, 8)]
  sessions = clients.map { |client| KIFMultiplayer::CardSession.new(client) }
  pokemon = TradeTestPokemon.new(trade_test_snapshot(700))
  original = Marshal.dump(pokemon)
  card = sessions[0].mine
  assert.call(card["avatar"] == "POKEMONTRAINER_Red" && !card["show_badges"] && card["badges"].empty?, "new card has registered avatar and badges hidden by default")
  assert.call(KIFMultiplayer::CardData.avatar_path("POKEMONTRAINER_Red") == "Graphics/Trainers/trainer000", "avatar uses trusted trainer registry filename resolver")
  reject.call("network avatar path rejected") { KIFMultiplayer::CardData.avatar("../../secret.png") }
  reject.call("well-shaped unknown trainer ID rejected") { KIFMultiplayer::CardData.avatar("UNREGISTERED") }
  draft = sessions[0].prepare_draft(pokemon, [])
  assert.call(sessions[0].drafts[draft["id"]]["snapshot"] == pokemon.snapshot["pokemon"], "full snapshot and privacy choices saved before publish")
  assert.call(Marshal.dump(pokemon) == original, "draft publication never mutates local Pokemon")
  preview = sessions[0].preview(draft)
  assert.call((preview.keys & %w[name owner iv ev personal_id item]).empty?, "preview excludes all hidden individual fields")
  assert.call(!preview["appearance"].key?("head_nickname"), "hidden fusion nickname excluded from public preview")
  service.fail_publish = true
  reject.call("offline publication retains original draft") { sessions[0].publish_draft(draft["id"]) }
  assert.call(sessions[0].drafts.key?(draft["id"]) && service.showcases.empty?, "failed new publish neither drops draft nor invents published entry")
  service.fail_publish = false
  first = sessions[0].publish_draft(draft["id"])
  assert.call(first["version"] == 1 && sessions[0].drafts.empty?, "successful publish assigns server code and clears completed draft")
  second_draft = sessions[0].prepare_draft(pokemon, %w[name owner])
  second = sessions[0].publish_draft(second_draft["id"])
  assert.call(first["code"] != second["code"] && sessions[0].owned_showcases.length == 2, "independent publishes keep multiple showcases instead of replacing one pointer")
  assert.call(sessions[0].account["showcase_code"] == second["code"] && sessions[0].account["showcase_codes"].sort == [first["code"], second["code"]].sort, "legacy single-entry pointer interoperates without losing multi-showcase library")
  service.showcases[second["code"]]["source"] = "server_managed"
  reject.call("server-managed showcase cannot become a local update draft") { sessions[0].prepare_draft(pokemon, [], second["code"]) }
  service.showcases[second["code"]].delete("source")
  update = sessions[0].prepare_draft(pokemon, %w[name iv ev], first["code"])
  service.fail_publish = true
  reject.call("failed update preserves old public version") { sessions[0].publish_draft(update["id"]) }
  assert.call(service.showcases[first["code"]]["version"] == 1 && !service.showcases[first["code"]]["snapshot"].key?("name"), "failed update leaves existing visible data byte-equivalent")
  persisted_profile = KIFMultiplayer::Profile.new(clients[0].profile.path)
  assert.call(persisted_profile.account["showcase_drafts"][update["id"]]["snapshot"] == update["snapshot"], "restart can recover complete failed update draft from disk")
  service.fail_publish = false
  clients[0].lose_next_response = true
  reject.call("lost successful publish response leaves same draft request ID") { sessions[0].publish_draft(update["id"]) }
  version_after_commit = service.versions
  updated = sessions[0].publish_draft(update["id"])
  assert.call(updated["version"] == 2 && service.versions == version_after_commit, "idempotent retry returns original update without a third version")
  assert.call(updated["snapshot"].key?("name") && updated["snapshot"].key?("iv") && !updated["snapshot"].key?("owner"), "published projection follows per-field opt-in")
  cards = sessions[0].update_card("POKEMONTRAINER_Leaf", true, [first["code"], second["code"]])
  assert.call(cards["showcases"].length == 2 && cards["avatar"] == "POKEMONTRAINER_Leaf" && cards["badges"].length == 1, "card stores avatar voluntary earned badge visibility and two references")
  remote = sessions[1].find(cards["friend_code"])
  assert.call(remote["id"] == clients[0].player_id && remote["showcases"].length == 2, "independent identity sees same authorized card projection")
  reject.call("card cannot include another owner's showcase") { sessions[1].update_card("POKEMONTRAINER_Red", false, [first["code"]]) }
  reject.call("more than six card references blocked before submit") { sessions[0].update_card("POKEMONTRAINER_Red", false, (1..7).map { |i| "%08X" % i }) }
  sessions[0].unpublish(first["code"])
  assert.call(sessions[1].find(cards["friend_code"])["showcases"].map { |entry| entry["code"] } == [second["code"]], "unpublished reference disappears from fresh card response")
  assert.call(sessions[0].owned_showcases.length == 1 && service.showcases[second["code"]]["active"], "unpublishing one showcase does not affect another")
  hidden = sessions[0].update_card("POKEMONTRAINER_Red", false, [second["code"]])
  assert.call(hidden["badges"].empty? && !hidden["show_badges"], "opt-out removes badge records from actual response")
  invalid = KIFMultiplayer::TradeCodec.copy(hidden)
  invalid["badges"] = [{ "id" => "forged", "kind" => "hosted_starter_grant" }]
  reject.call("non-medal grant records cannot be exposed as earned card badges") { KIFMultiplayer::CardData.card(invalid) }
  invalid = KIFMultiplayer::TradeCodec.copy(second)
  invalid["snapshot"]["personal_id"] = 123
  reject.call("public showcase rejects leaked hidden individual fields") { KIFMultiplayer::CardData.showcase(invalid) }
  invalid = KIFMultiplayer::TradeCodec.copy(second)
  invalid["snapshot"]["moves"] = [true]
  reject.call("malformed public move cannot reach renderer") { KIFMultiplayer::CardData.showcase(invalid) }
  assert.call(Marshal.dump(pokemon) == original, "all card editing publishing viewing and unpublishing leaves original Pokemon untouched")
  # A successful POST followed by a local profile write failure must retain
  # the same in-memory draft/request ID as the on-disk recovery version.
  draft = sessions[0].prepare_draft(pokemon, [])
  draft_id = draft["id"]
  profile = clients[0].profile
  save = profile.method(:save)
  failed = false
  profile.define_singleton_method(:save) do
    if !failed && !(account["showcase_drafts"] || {}).key?(draft_id)
      failed = true
      raise IOError, "profile failed after successful publish"
    end
    save.call
  end
  begin
    sessions[0].publish_draft(draft_id)
    raise "expected profile failure"
  rescue IOError
    assert.call(sessions[0].drafts[draft_id] == draft, "successful remote publish plus profile failure preserves full memory draft")
  end
  versions = service.versions
  result = sessions[0].publish_draft(draft_id)
  assert.call(service.versions == versions && !sessions[0].drafts.key?(draft_id), "draft retry reuses request ID without duplicate showcase or version")
  assert.call(sessions[0].account["showcase_codes"].include?(result["code"]), "publish retry durably adds original committed showcase to library")
  profile.define_singleton_method(:save, save)
  log.puts("CARDS_TEST_PASS checks=#{checks}")
  puts("CARDS_TEST_PASS checks=#{checks} evidence=#{TRADE_TEST_DIR}")
rescue StandardError => error
  log.puts("CARDS_TEST_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  raise
ensure
  log.close
end
