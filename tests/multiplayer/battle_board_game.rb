# Native screenshot/layout proof for the public observer/replay board only.
# Combat and transport are not executed by this isolated display fixture.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  PokemonSprite.prepend(Module.new do
    def setPokemonBitmap(pokemon, *arguments)
      @board_test_pokemon = pokemon
      super
    end
  end)
  species = %w[PALKIA KYOGRE B76H95 LUGIA]
  names = ["Shiny Palkia", "Kyogre", "Golem-Onix", "Lugia"]
  battlers = species.each_with_index.map do |id, index|
    {"owner_id" => index == 1 ? "boss" : "public_player", "index" => index, "party_index" => 0,
     "species" => id, "name" => names[index], "level" => 50, "hp" => 73 - index * 17,
     "totalhp" => index == 2 ? 1326 : 200, "status" => %w[BURN NONE PARALYSIS SLEEP][index]}
  end
  public = battlers.map do |entry|
    {"slot" => entry["index"], "species" => entry["species"], "level" => 50,
     "party_index" => 0, "form" => 0, "name" => entry["name"], "hp" => entry["hp"],
     "totalhp" => entry["totalhp"], "status" => entry["status"], "gender" => entry["index"] == 2 ? 1 : 2,
     "shiny" => entry["index"] == 0, "appearance" => entry["index"] == 0 ?
       {"shinyValue" => 120, "shinyR" => 4, "shinyG" => 2, "shinyB" => 3,
        "shinyKRS" => [0, 0, 0, 0, 0, 0, 0, 0, 0], "size_category" => "LARGE"} : {}}
  end
  references = test.globals
  original = test.digest(references)
  result = {"pid" => Process.pid, "ruby" => RUBY_VERSION, "viewport_width" => Graphics.width,
            "viewport_height" => Graphics.height, "layouts" => []}
  KIFMultiplayer.with_ui_fonts do
    KIFMultiplayer::BattleIsolation.with do
      [3, 4].each do |count|
        board, capture = nil, nil
        begin
          state = {"battlers" => battlers.first(count), "visuals" => {"version" => 1, "seq" => 1,
            "complete" => true, "events" => [], "battlers" => public.first(count)}}
          board = KIFMultiplayer::BattleBoard.new(state)
          sprites = board.instance_variable_get(:@sprites)
          test.check(sprites.length == count + 1 && !board.instance_variable_get(:@viewport).disposed?, "native board #{count}: resources initialized")
          bounds = sprites.drop(1).each_with_index.map do |sprite, index|
            left = sprite.x - sprite.ox * sprite.zoom_x
            right = sprite.x + (sprite.bitmap.width - sprite.ox) * sprite.zoom_x
            top = sprite.y - sprite.oy * sprite.zoom_y
            test.check(left >= index * Graphics.width / count + 7 &&
              right <= (index + 1) * Graphics.width / count - 7 && top >= 27, "native board #{count}: slot#{index} bounds")
            {"slot" => index, "left" => left, "right" => right, "top" => top, "bottom" => sprite.y,
             "bitmap_width" => sprite.bitmap.width, "bitmap_height" => sprite.bitmap.height, "scale" => sprite.zoom_x}
          end
          pokemon = sprites[1].instance_variable_get(:@board_test_pokemon)
          test.check(pokemon.shiny? && pokemon.gender == 2 && pokemon.instance_variable_get(:@shinyR) == 4 &&
            pokemon.instance_variable_get(:@size_category) == :LARGE, "native board #{count}: validated custom shiny appearance reached actual sprite")
          5.times { Graphics.update }
          capture = Graphics.snap_to_bitmap
          image_path = File.join(directory, "battle-board-#{count}.png")
          capture.to_file(image_path)
          result["layouts"] << {"count" => count, "bounds" => bounds, "screenshot" => image_path,
                                  "custom_shiny" => true, "local_font_size" => sprites.first.bitmap.font.size}
        ensure
          capture.dispose if capture && !capture.disposed?
          board.dispose if board
        end
      end
    end
  end
  test.check(original == test.digest(references) && references.each_with_index.all? { |value, i| value.equal?(test.globals[i]) },
             "native board: original global identities and contents restored")
  result["finished"] = true
  File.write(File.join(directory, "battle-board-evidence.json"), KIFMultiplayer::WireJSON.dump(result))
  test.log("BATTLE_BOARD_NATIVE_PASS layouts=2 custom_shiny=true globals_unchanged=true")
  passed = true
rescue Exception => error
  $kif_test_log.call("BATTLE_BOARD_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
