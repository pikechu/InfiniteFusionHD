# Minimal bundled-runtime asset probe: no RPG scripts, maps, multiplayer,
# transport, battle, or replay code is loaded.
passed = false
begin
  load "scripts/multiplayer/runtime-preload.rb"
  log_path = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "pixman-bitmap.log")
  log = lambda { |line| File.open(log_path, "a") { |file| file.puts(line); file.flush } }
  log.call("PIXMAN_PROBE_BEGIN pid=#{Process.pid} no_rpg=true no_multiplayer=true no_network=true")
  bitmap = Bitmap.new("Graphics/Tilesets/Indoor.PNG")
  log.call("PIXMAN_ASSET_LOADED width=#{bitmap.width} height=#{bitmap.height} mega=#{bitmap.mega?}")
  bitmap.dispose
  log.call("PIXMAN_BITMAP_PROBE_PASS")
  passed = true
rescue Exception => error
  log.call("PIXMAN_BITMAP_PROBE_FAIL #{error.class}: #{error.message}") if defined?(log) && log
ensure
  exit!(passed ? 0 : 1)
end
