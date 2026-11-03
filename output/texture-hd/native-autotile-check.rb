# Render every source animation frame through the production autotile assembler.
directory = File.expand_path("output/texture-hd/p1-evidence/native-autotiles")
Dir.mkdir(directory) unless File.directory?(directory)
logfile = File.join(directory, "result.txt")
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  tasks = KIFMultiplayer::WireJSON.parse(File.binread("output/texture-hd/p1-autotile-work/tasks.json"))
  decisions = KIFMultiplayer::WireJSON.parse(File.binread("output/texture-hd/p1-evidence/map-review-decisions.json"))
  rendered = 0
  input_hashes = {}
  File.write(logfile, "NATIVE_AUTOTILE_BEGIN files=#{tasks.length}\n")
  tasks.each do |task|
    paths = ["originals", "ready"].map { |folder| "output/texture-hd/#{task['batch']}/#{folder}/#{task['source']}" }
    paths[1] = paths[0] if decisions.dig(task['source'], 'action') == 'preserve'
    input_hashes[task['source']] = {"before" => Digest::SHA256.hexdigest(File.binread(paths[0])), "after" => Digest::SHA256.hexdigest(File.binread(paths[1]))}
    helpers = paths.map do |path|
      source = Bitmap.new(path)
      raise "Autotile dimensions changed" unless source.width == task['size'][0] && source.height == task['size'][1]
      expanded = TilemapRenderer::AutotileExpander.expand(source)
      raise "Expansion lost frames" unless [task['frames'] * 32, task['frames'] * 64].include?(expanded.width)
      expanded.dispose if expanded != source
      TileDrawingHelper.new(Bitmap.new(32,32), [source])
    end
    task['frames'].times do |frame|
      image = Bitmap.new(512,192)
      image.fill_rect(0,0,512,192,Color.new(48,56,65))
      helpers.each_with_index do |helper, side|
        48.times { |pattern| helper.bltTile(image, side * 256 + pattern % 8 * 32, pattern / 8 * 32, 48 + pattern, frame) }
      end
      image.to_file(File.join(directory,"#{task['key']}-frame-#{format('%02d',frame)}.png"))
      image.dispose
      rendered += 1
      Graphics.update
    end
    helpers.each(&:dispose)
    File.open(logfile,"a") { |file| file.puts("AUTOTILE_RENDERED #{task['source']} frames=#{task['frames']} patterns=48") }
  end
  File.open(logfile,"a") { |file| file.puts("NATIVE_AUTOTILE_PASS files=#{tasks.length} frames=#{rendered} patterns_per_frame=48") }
  File.write(File.join(directory,"inputs.json"), HTTPLite::JSON.stringify(input_hashes))
  passed = true
rescue Exception => error
  File.open(logfile,"a") { |file| file.puts("NATIVE_AUTOTILE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
ensure
  exit!(passed ? 0 : 1)
end
