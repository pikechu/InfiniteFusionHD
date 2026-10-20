# No game scripts, player data or external files are read by this fixture.
module Kernel
  def puts(*values)
    values.each { |value| System.puts(value.to_s) }
  end
end

# KIF_NATIVE_PROBE_STORAGE_GUARD_BEGIN
module KIFNativeProbeStorage
  def self.output_directory(files_path, output_path)
    # Android exposes /data/data and /data/user/0 aliases for the same app.
    # Resolve both before enforcing the private, dedicated child boundary.
    files = File.realpath(files_path)
    output = File.realpath(output_path)
    boundary = File.join(files, "native-probe") + File::SEPARATOR
    raise "Probe output escaped application private files" unless output.start_with?(boundary)
    output
  end
end
# KIF_NATIVE_PROBE_STORAGE_GUARD_END

# KIF_NATIVE_PROBE_MARSHAL_DIAGNOSTICS_BEGIN
module KIFNativeProbeMarshalDiagnostics
  def self.bytes(data)
    { "bytesize" => data.bytesize, "sha256" => Digest::SHA256.hexdigest(data),
      "headerHex" => (data.byteslice(0, 16) || "").unpack1("H*"),
      "prefixHex" => (data.byteslice(0, 128) || "").unpack1("H*"),
      "prefixTruncated" => data.bytesize > 128 }
  end

  def self.describe(value, depth = 0)
    item = { "class" => value.class.to_s }
    return item.merge("depthLimit" => true) if depth > 8
    case value
    when String
      item.merge!(bytes(value)).merge!({ "encoding" => value.encoding.name,
        "validEncoding" => value.valid_encoding?, "asciiOnly" => value.ascii_only?,
        "escapedPreview" => value.byteslice(0, 128).dump })
    when Symbol
      item.merge!({ "name" => value.to_s, "nameEncoding" => value.to_s.encoding.name })
    when Hash
      item["size"] = value.size
      item["entries"] = value.first(32).map { |key, entry| {
        "key" => describe(key, depth + 1), "value" => describe(entry, depth + 1) } }
      item["entriesTruncated"] = value.size > 32
    when Array
      item["length"] = value.length
      item["items"] = value.first(32).map { |entry| describe(entry, depth + 1) }
      item["itemsTruncated"] = value.length > 32
    when Integer, TrueClass, FalseClass, NilClass
      item["value"] = value
    else
      item["escapedInspect"] = value.inspect
    end
    item
  end

  def self.compare(expected, restored, path = "$", depth = 0)
    item = { "path" => path, "expectedClass" => expected.class.to_s,
      "restoredClass" => restored.class.to_s, "strictEqual" => restored == expected,
      "eql" => restored.eql?(expected) }
    return item.merge("depthLimit" => true) if depth > 8
    if expected.is_a?(String) && restored.is_a?(String)
      compatible = Encoding.compatible?(expected, restored)
      item.merge!({ "bytesEqual" => restored.bytes == expected.bytes,
        "expectedEncoding" => expected.encoding.name, "restoredEncoding" => restored.encoding.name,
        "compatibleEncoding" => compatible && compatible.name,
        "expected" => describe(expected), "restored" => describe(restored) })
    elsif expected.is_a?(Hash) && restored.is_a?(Hash)
      item["expectedKeys"] = expected.keys.map { |key| describe(key) }
      item["restoredKeys"] = restored.keys.map { |key| describe(key) }
      item["fields"] = expected.first(32).map do |key, value|
        present = restored.key?(key)
        { "expectedKey" => describe(key), "restoredHasExpectedKey" => present,
          "comparison" => present ? compare(value, restored[key], path + "[" + key.inspect + "]", depth + 1) : nil }
      end
      item["unexpectedRestoredKeys"] = restored.keys.reject { |key| expected.key?(key) }.map { |key| describe(key) }
    elsif expected.is_a?(Array) && restored.is_a?(Array)
      item["expectedLength"], item["restoredLength"] = expected.length, restored.length
      item["items"] = expected.first(32).each_with_index.map do |value, index|
        { "index" => index, "restoredPresent" => index < restored.length,
          "comparison" => index < restored.length ? compare(value, restored[index], path + "[#{index}]", depth + 1) : nil }
      end
    else
      item["expected"], item["restored"] = describe(expected), describe(restored)
    end
    item
  end

  def self.report(original, restored, disk_dump, memory_dump)
    { "scope" => "only this process's freshly written probe.dat",
      "expected" => describe(original), "restored" => describe(restored),
      "comparison" => compare(original, restored), "diskDump" => bytes(disk_dump),
      "memoryOriginalDump" => bytes(memory_dump), "diskBytesEqualMemoryDump" => disk_dump == memory_dump,
      "marshalHeaderBytes" => disk_dump.bytes.first(2),
      "marshalFormat" => "#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION}",
      "defaultExternalEncoding" => Encoding.default_external.name,
      "defaultInternalEncoding" => Encoding.default_internal && Encoding.default_internal.name }
  end

  def self.same_bytes_and_types?(expected, restored)
    return false unless expected.class == restored.class
    case expected
    when String
      expected.bytes == restored.bytes
    when Array
      expected.length == restored.length && expected.each_with_index.all? { |item, index| same_bytes_and_types?(item, restored[index]) }
    when Hash
      expected.size == restored.size && expected.all? { |key, item| restored.key?(key) && same_bytes_and_types?(item, restored[key]) }
    else
      restored == expected
    end
  end

  def self.assert_contracts(original, restored, unwrapped, expected_utf8, contracts)
    original_binary = original.is_a?(Hash) && original[:values].is_a?(Array) ? original[:values][3] : nil
    restored_binary = restored.is_a?(Hash) && restored[:values].is_a?(Array) ? restored[:values][3] : nil
    contracts.merge!({ "nativeAliasStrictBinaryEqual" => unwrapped == original,
      "publicLoadStrictExpectedUTF8Equal" => restored == expected_utf8,
      "publicLoadPreservesEveryStringByteAndValueType" => same_bytes_and_types?(original, restored),
      "publicLoadStrictOriginalEqual" => restored == original,
      "originalBinaryFixtureEncoding" => original_binary.is_a?(String) ? original_binary.encoding.name : nil,
      "publicBinaryFixtureEncoding" => restored_binary.is_a?(String) ? restored_binary.encoding.name : nil })
    # Two distinct contracts, both strict; this never substitutes byte-only
    # equality for the native binary roundtrip or the public RGSS UTF8 result.
    raise "Native binary Marshal roundtrip mismatch" unless unwrapped == original
    raise "RGSS public Marshal UTF8 contract mismatch" unless restored == expected_utf8
    raise "RGSS public Marshal changed bytes or value types" unless contracts["publicLoadPreservesEveryStringByteAndValueType"]
    unless contracts["originalBinaryFixtureEncoding"] == "ASCII-8BIT" &&
        contracts["publicBinaryFixtureEncoding"] == "UTF-8" && restored != original
      raise "Expected RGSS encoding-only difference was not observed"
    end
    contracts["status"] = "pass"
  end
end
# KIF_NATIVE_PROBE_MARSHAL_DIAGNOSTICS_END

result = { "status" => "running", "ruby" => RUBY_VERSION,
  "platform" => RUBY_PLATFORM, "fullRuntimeSourceBuild" => false }
files = ENV.fetch("KIF_ANDROID_FILES")
supplied_output = ENV.fetch("KIF_NATIVE_PROBE_OUTPUT")
output = KIFNativeProbeStorage.output_directory(files, supplied_output)
puts "KIF_NATIVE_PROBE_STORAGE canonical_files=#{File.realpath(files)} canonical_output=#{output} expanded_files=#{File.expand_path(files)} expanded_output=#{File.expand_path(supplied_output)}"
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
  result["stage"] = "Marshal roundtrip"
  path = File.join(output, "probe.dat")
  original = { :version => 1, :name => "native-probe", :values => [1, 2, 3, source] }
  File.open(path, "wb") { |stream| Marshal.dump(original, stream) }
  restored = File.open(path, "rb") { |stream| Marshal.load(stream) }
  result["marshalDiagnostics"] = { "wrappedStrictEqual" => restored == original }
  begin
    disk_dump = File.binread(path)
    result["marshalDiagnostics"].merge!(KIFNativeProbeMarshalDiagnostics.report(original, restored, disk_dump, Marshal.dump(original)))
  rescue StandardError => diagnostic_error
    result["marshalDiagnostics"]["diagnosticError"] = "#{diagnostic_error.class}: #{diagnostic_error.message}"
  end
  result["stage"] = "Marshal native binary and RGSS UTF8 contracts"
  result["marshalContracts"] = { "nativeAliasAvailable" => Marshal.respond_to?(:_mkxp_load_alias) }
  raise "Native Marshal load alias unavailable" unless Marshal.respond_to?(:_mkxp_load_alias)
  unwrapped = File.open(path, "rb") { |stream| Marshal._mkxp_load_alias(stream) }
  result["marshalDiagnostics"]["unwrappedAliasComparison"] = KIFNativeProbeMarshalDiagnostics.compare(original, unwrapped)
  # Independent expected RGSS object: only the binary fixture's encoding tag
  # changes to UTF8, matching the fixed engine's documented load callback.
  expected_utf8 = { :version => 1, :name => "native-probe",
    :values => [1, 2, 3, source.dup.force_encoding(Encoding::UTF_8)] }
  result["marshalDiagnostics"]["publicExpectedUTF8"] = KIFNativeProbeMarshalDiagnostics.describe(expected_utf8)
  KIFNativeProbeMarshalDiagnostics.assert_contracts(original, restored, unwrapped, expected_utf8, result["marshalContracts"])
  puts "KIF_NATIVE_PROBE_MARSHAL_PASS native_alias_strict=true rgss_expected_utf8_strict=true bytes_and_types=true encoding_only_difference=true"
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
