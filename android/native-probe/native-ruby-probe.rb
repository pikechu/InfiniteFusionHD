# No game scripts, player data or external files are read by this fixture.
module Kernel
  def puts(*values)
    values.each { |value| System.puts(value.to_s) }
  end
end

result = { "status" => "running", "ruby" => RUBY_VERSION,
  "platform" => RUBY_PLATFORM, "fullRuntimeSourceBuild" => false }
output = ENV.fetch("KIF_NATIVE_PROBE_OUTPUT")
files = ENV.fetch("KIF_ANDROID_FILES")
raise "Probe output escaped application private files" unless File.expand_path(output).start_with?(File.expand_path(files) + "/native-probe/")
result_path = File.join(output, "probe-result.json")
begin
  puts "KIF_NATIVE_PROBE_BEGIN ruby=#{RUBY_VERSION} platform=#{RUBY_PLATFORM}"
  ["openssl", "socket", "zlib", "digest", "digest/sha2"].each do |name|
    result["stage"] = "require #{name}"
    require name
    puts "KIF_NATIVE_PROBE_REQUIRE_PASS #{name}"
  end
  result["stage"] = "module functions"
  expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  raise "Digest SHA256 mismatch" unless Digest::SHA256.hexdigest("abc") == expected
  raise "OpenSSL SHA256 mismatch" unless OpenSSL::Digest::SHA256.hexdigest("abc") == expected
  raise "Socket address mismatch" unless Addrinfo.ip("127.0.0.1").ip_address == "127.0.0.1"
  source = ("Native Ruby Probe\0\u878D\u5408" * 32).b
  raise "Zlib roundtrip mismatch" unless Zlib::Inflate.inflate(Zlib::Deflate.deflate(source)) == source
  # This file is freshly overwritten by this process before any Marshal.load.
  path = File.join(output, "probe.dat")
  original = { :version => 1, :name => "native-probe", :values => [1, 2, 3, source] }
  File.open(path, "wb") { |stream| Marshal.dump(original, stream) }
  restored = File.open(path, "rb") { |stream| Marshal.load(stream) }
  raise "Marshal roundtrip mismatch" unless restored == original
  # Also invoke the existing source-built JNI helper against the new Ruby ABI.
  require File.join(ENV.fetch("KIF_NATIVE_LIB_DIR"), "libkif_android_bridge.so")
  raise "JNI bridge Ruby module missing" unless defined?(KIFAndroidBridge)
  input = KIFAndroidBridge.input_poll
  raise "JNI bridge input result mismatch" unless input == [0, 0, 0]
  puts "KIF_NATIVE_PROBE_MODULES_PASS openssl=#{OpenSSL::OPENSSL_VERSION} zlib=#{Zlib::ZLIB_VERSION} digest=SHA256 socket=Addrinfo marshal=#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION} bridge=input_poll"
  load "runtime-smoke.rb"
  result["stage"] = "graphics/font/120 frames"
  graphics = NativeProbeSmoke.run
  sprite = graphics.delete("sprite")
  bitmap = graphics.delete("bitmap")
  result.merge!(graphics)
  result.merge!({ "status" => "pass", "openssl" => OpenSSL::OPENSSL_VERSION,
    "zlib" => Zlib::ZLIB_VERSION, "modules" => ["openssl", "socket", "zlib", "digest/sha2"],
    "marshal" => "#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION}", "jniBridge" => true })
  File.binwrite(result_path, HTTPLite::JSON.stringify(result))
  puts "KIF_NATIVE_PROBE_PASS frames=120 elapsed=#{graphics['elapsedSeconds']} result=#{result_path}"
  # Keep the rendered success evidence visible until the separately controlled process ends.
  loop { Graphics.update; Input.update }
rescue Exception => error
  result.merge!({ "status" => "fail", "error" => "#{error.class}: #{error.message}",
    "backtrace" => error.backtrace || [] })
  File.binwrite(result_path, HTTPLite::JSON.stringify(result))
  puts "KIF_NATIVE_PROBE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join('\n')}"
  raise
end
