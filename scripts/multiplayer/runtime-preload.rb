# Local developer launch only. Never read or migrate the player's normal saves.
directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
raise "An absolute test save directory is required" unless directory =~ /\A(?:[A-Za-z]:[\\\/]|\/)/
directory = File.expand_path(directory).tr("\\", "/") + "/"
raise "Test save directory does not exist" unless File.directory?(directory)
System.define_singleton_method(:data_directory) { directory }
$kif_multiplayer_runtime_log = File.join(directory, "runtime.log")
File.open($kif_multiplayer_runtime_log, "a") do |file|
  file.puts "PRELOAD pid=#{Process.pid} ruby=#{RUBY_VERSION} save_dir=#{directory} utc=#{Time.now.utc}"
end
# Observe the normal Scripts.rxdata loader without modifying it. The loader
# reports basenames to eval, whereas the explicit diagnostic uses full paths.
observed = {}
expected = Dir["Data/Scripts/054_Multiplayer/*.rb"].map { |path| File.basename(path) }.sort
trace = TracePoint.new(:class, :line) do |event|
  basename = File.basename(event.path)
  if expected.include?(basename) && event.event == :class && !observed[basename]
    observed[basename] = true
    File.open($kif_multiplayer_runtime_log, "a") do |file|
      file.puts "PRODUCTION_SOURCE_EVALUATED #{basename} trace_path=#{event.path} pid=#{Process.pid}"
    end
  end
  # Verify the final methods only after execution returns from the last module
  # to its loader/main. The first :class event proves entry, not file completion.
  if !expected.include?(basename) && event.event == :line && observed.length == expected.length
    locations = []
    locations << KIFMultiplayer::HTTPTransport.instance_method(:call).source_location if defined?(KIFMultiplayer::HTTPTransport)
    locations << KIFMultiplayer::BattleBoard.instance_method(:initialize).source_location if defined?(KIFMultiplayer::BattleBoard)
    locations << KIFMultiplayer::ReplayData.method(:validate).source_location if defined?(KIFMultiplayer::ReplayData)
    next if expected.include?("015_Transport.rb") && (!locations[0] || File.basename(locations[0][0]) != "015_Transport.rb")
    manifest = if File.file?("Data/multiplayer-build.json")
                 KIFMultiplayer::WireJSON.parse(File.binread("Data/multiplayer-build.json"))
               else
                 {}
               end
    File.open($kif_multiplayer_runtime_log, "a") do |file|
      file.puts "PRODUCTION_MODULES_EVALUATED count=#{observed.length} pid=#{Process.pid}"
      file.puts "PRODUCTION_FINAL_METHODS #{locations.map { |location| location.join(':') }.join(',')} data_hash=#{manifest['data_hash']}"
    end
    trace.disable
  end
end
trace.enable
