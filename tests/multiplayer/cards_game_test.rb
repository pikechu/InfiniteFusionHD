# Two real HTTP identities inside an actual Game.exe; avatar uses real Sprite,
# AnimatedBitmap and Graphics screenshot. No player's normal save is loaded.
module KIFMultiplayerCardsGameTest
  def self.run(log)
    directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
    raise "Cards test must use isolated saves" unless File.expand_path(System.data_directory) == File.expand_path(directory)
    clients = %w[owner viewer].map do |role|
      profile = KIFMultiplayer::Profile.new(File.join(directory, "cards-#{role}.json"))
      client = KIFMultiplayer::Client.new(profile)
      client.connect("Cards #{role}")
      client
    end
    owner, viewer = clients
    owner.compatibility
    sessions = clients.map { |client| KIFMultiplayer::CardSession.new(client) }
    checks = 0
    assert = lambda do |condition, message|
      raise "CARDS_GAME_FAIL #{message}" unless condition
      checks += 1; log.call("CARDS_GAME_PASS #{message}")
    end
    pokemon = Pokemon.new(:B1H4, 24, $Trainer, true, false)
    pokemon.name = "Hidden Card Nick"
    pokemon.head_nickname = "Hidden Fusion Head"
    pokemon.shiny = true
    pokemon.head_shinyhue = 93
    original = Marshal.dump(pokemon)
    first_draft = sessions[0].prepare_draft(pokemon, [])
    transport = owner.transport
    fail_before = true
    proxy = Object.new
    proxy.define_singleton_method(:call) do |method, url, body, token, timeout|
      if fail_before && method == "POST" && url.end_with?("/v1/showcases")
        fail_before = false
        raise IOError, "test publication disconnect before upload"
      end
      transport.call(method, url, body, token, timeout)
    end
    failing_owner = KIFMultiplayer::Client.new(owner.profile, proxy)
    failing_session = KIFMultiplayer::CardSession.new(failing_owner)
    begin
      failing_session.publish_draft(first_draft["id"])
      raise "Expected publication disconnect"
    rescue KIFMultiplayer::UncertainRequest
      assert.call(failing_session.drafts[first_draft["id"]]["snapshot"] == first_draft["snapshot"], "real network failure retains full draft snapshot and visibility")
    end
    first = failing_session.publish_draft(first_draft["id"])
    assert.call(first["version"] == 1 && failing_session.drafts.empty?, "real operation recovery publishes first draft once")
    second_draft = sessions[0].prepare_draft(pokemon, %w[name])
    second = sessions[0].publish_draft(second_draft["id"])
    assert.call(sessions[0].owned_showcases.length == 2 && first["code"] != second["code"], "real service retains two independently managed showcases")
    card = sessions[0].update_card("POKEMONTRAINER_Leaf", false, [first["code"], second["code"]])
    remote = sessions[1].find(card["friend_code"])
    assert.call(remote["showcases"].map { |value| value["code"] } == [first["code"], second["code"]], "independent authenticated identity sees ordered card showcase references")
    hidden = remote["showcases"].first["snapshot"]
    assert.call(!hidden.key?("name") && !hidden.key?("owner") && !hidden.key?("iv") && !hidden["appearance"].key?("head_nickname"), "public card response omits hidden nickname trainer IV and fusion nickname")
    assert.call(remote["badges"].empty? && remote["show_badges"] == false, "private badge setting removes records from public response")
    update_draft = sessions[0].prepare_draft(pokemon, %w[name iv], first["code"])
    lose_after = true
    lost_proxy = Object.new
    lost_proxy.define_singleton_method(:call) do |method, url, body, token, timeout|
      result = transport.call(method, url, body, token, timeout)
      if lose_after && method == "POST" && url.end_with?("/v1/showcases")
        lose_after = false
        raise IOError, "test response lost after committed showcase update"
      end
      result
    end
    updating = KIFMultiplayer::CardSession.new(KIFMultiplayer::Client.new(owner.profile, lost_proxy))
    begin
      updating.publish_draft(update_draft["id"])
      raise "Expected lost publication response"
    rescue KIFMultiplayer::UncertainRequest
      assert.call(updating.drafts.key?(update_draft["id"]), "committed response loss retains original idempotent update draft")
    end
    updated = updating.publish_draft(update_draft["id"])
    assert.call(updated["version"] == 2, "real repeated update request returns same version rather than publishing twice")
    updated_remote = sessions[1].find(card["friend_code"])
    assert.call(updated_remote["showcases"].first["snapshot"].key?("iv") && !updated_remote["showcases"].first["snapshot"].key?("owner"), "independent card reflects only newly opted-in showcase fields")
    avatar = window = nil
    begin
      avatar = KIFMultiplayer::CardAvatar.new(remote["avatar"])
      assert.call(avatar.sprite.bitmap.width > 0 && avatar.sprite.bitmap.height > 0, "actual registered trainer sprite decodes into a real game Sprite")
      16.times { avatar.update; Graphics.update; Input.update }
      avatar_only = File.join(directory, "trainer-card-avatar-only.png")
      Graphics.screenshot(avatar_only)
      log.call("CARDS_AVATAR_ONLY_SCREENSHOT #{avatar_only} visible=#{avatar.sprite.visible} opacity=#{avatar.sprite.opacity} size=#{avatar.sprite.bitmap.width}x#{avatar.sprite.bitmap.height} xy=#{avatar.sprite.x},#{avatar.sprite.y}")
      window = Window_AdvancedTextPokemon.new("联机训练师名片\n#{KIFMultiplayer.display_text(remote['nickname'])}\n好友码 #{remote['friend_code']}\n展柜 2 / 6 · 徽章未公开")
      window.x, window.y, window.width = 0, Graphics.height - 144, Graphics.width
      30.times { avatar.update; window.update; Graphics.update; Input.update }
      screenshot = File.join(directory, "trainer-card-avatar.png")
      Graphics.screenshot(screenshot)
      assert.call(File.file?(screenshot) && File.size(screenshot) > 100, "real rendered trainer avatar screenshot saved")
      log.call("CARDS_AVATAR_SCREENSHOT #{screenshot}")
    ensure
      window.dispose if window && !window.disposed?
      avatar.dispose if avatar
    end
    sessions[0].unpublish(first["code"])
    assert.call(sessions[1].find(card["friend_code"])["showcases"].map { |value| value["code"] } == [second["code"]], "unpublishing removes only that reference from fresh public card")
    assert.call(Marshal.dump(pokemon) == original, "drafts publishing viewing avatar and unpublishing leave real original Pokemon unchanged")
    log.call("CARDS_GAME_TEST_PASS checks=#{checks} owner=#{owner.player_id} viewer=#{viewer.player_id}")
    checks
  end
end
