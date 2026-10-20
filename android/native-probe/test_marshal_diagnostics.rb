# Host-only: reproduce the exact fixed mkxp callback behavior using Ruby's load proc.
# No Android target, game save, external Marshal input or APK builder is invoked.
require 'digest'
require 'digest/sha2'

fixture = File.read(File.join(__dir__, 'native-ruby-probe.rb'), encoding: 'UTF-8').gsub("\r\n", "\n")
guard = fixture.split("# KIF_NATIVE_PROBE_MARSHAL_DIAGNOSTICS_BEGIN\n", 2).last
guard = guard.split("# KIF_NATIVE_PROBE_MARSHAL_DIAGNOSTICS_END", 2).first
raise 'Marshal diagnostic fixture markers missing' unless guard.include?('module KIFNativeProbeMarshalDiagnostics')
eval(guard, TOPLEVEL_BINDING, 'native-ruby-probe.rb Marshal diagnostics')
checks = 0
assert = proc { |value, message| raise message unless value; checks += 1 }
source = ("Native Ruby Probe\0\u878D\u5408" * 32).b
original = { :version => 1, :name => 'native-probe', :values => [1, 2, 3, source] }
dump = Marshal.dump(original)
ordinary = Marshal.load(dump)
assert.call(ordinary == original, 'host native roundtrip failed')
ordinary_report = KIFNativeProbeMarshalDiagnostics.report(original, ordinary, dump, dump)
assert.call(ordinary_report['comparison']['strictEqual'], 'ordinary equality not reported')
callback = proc do |object|
  object.force_encoding(Encoding::UTF_8) if object.is_a?(String) && object.encoding == Encoding::ASCII_8BIT
  object
end
wrapped = Marshal.load(dump, callback)
assert.call(wrapped != original, 'exact source callback did not reproduce the binary string mismatch')
report = KIFNativeProbeMarshalDiagnostics.report(original, wrapped, dump, dump)
assert.call(report['comparison']['strictEqual'] == false, 'wrapped failure was hidden')
assert.call(report['diskBytesEqualMemoryDump'], 'dump equality report incorrect')
assert.call(report['diskDump']['sha256'] == Digest::SHA256.hexdigest(dump), 'dump SHA incorrect')
assert.call(report['marshalHeaderBytes'] == [4, 8], 'Marshal header missing')
assert.call(report['expected']['entries'].all? { |entry| entry['key']['class'] == 'Symbol' }, 'expected key types missing')
fields = report['comparison']['fields']
assert.call(fields.length == 3 && fields.all? { |field| field['restoredHasExpectedKey'] }, 'field inventory incomplete')
array = fields.find { |field| field['expectedKey']['name'] == 'values' }['comparison']
assert.call(array['items'].length == 4, 'array items not individually diagnosed')
string = array['items'][3]['comparison']
assert.call(string['strictEqual'] == false && string['bytesEqual'], 'encoding-only mismatch not distinguished from byte corruption')
assert.call(string['expectedEncoding'] == 'ASCII-8BIT' && string['restoredEncoding'] == 'UTF-8', 'encodings missing')
assert.call(string['expected']['sha256'] == string['restored']['sha256'], 'same binary content hashes differ')
assert.call(string['expected']['validEncoding'] && string['restored']['validEncoding'], 'valid encoding diagnostic incorrect')
assert.call(string['expected']['prefixHex'].ascii_only? && string['expected']['escapedPreview'].ascii_only?, 'diagnostic includes raw binary JSON text')
walk = proc do |value|
  case value
  when Hash
    value.each { |key, item| assert.call(key.is_a?(String), 'non-string JSON key'); walk.call(item) }
  when Array
    value.each { |item| walk.call(item) }
  when String
    assert.call(value.valid_encoding?, 'invalid diagnostic JSON string')
  else
    assert.call(value.nil? || value == true || value == false || value.is_a?(Numeric), 'unsupported JSON diagnostic type')
  end
end
walk.call(report)
expected_utf8 = { :version => 1, :name => 'native-probe',
  :values => [1, 2, 3, source.dup.force_encoding(Encoding::UTF_8)] }
contracts = {}
KIFNativeProbeMarshalDiagnostics.assert_contracts(original, wrapped, ordinary, expected_utf8, contracts)
assert.call(contracts['status'] == 'pass' && contracts['nativeAliasStrictBinaryEqual'], 'native strict contract did not pass')
assert.call(contracts['publicLoadStrictExpectedUTF8Equal'] && contracts['publicLoadPreservesEveryStringByteAndValueType'], 'public UTF8 contract did not pass')
[[wrapped, wrapped, 'Native binary Marshal roundtrip mismatch'],
 [ordinary, ordinary, 'RGSS public Marshal UTF8 contract mismatch']].each do |public_value, native_value, message|
  begin
    KIFNativeProbeMarshalDiagnostics.assert_contracts(original, public_value, native_value, expected_utf8, {})
    raise 'broken contract accepted'
  rescue RuntimeError => error
    assert.call(error.message == message, 'wrong contract failure')
  end
end
corrupt = Marshal.load(Marshal.dump(wrapped))
corrupt[:values][3].setbyte(0, 88)
begin
  KIFNativeProbeMarshalDiagnostics.assert_contracts(original, corrupt, ordinary, expected_utf8, {})
  raise 'byte corruption accepted'
rescue RuntimeError => error
  assert.call(error.message == 'RGSS public Marshal UTF8 contract mismatch', 'byte corruption not rejected')
end
STDOUT.puts "PASS: #{checks} host-only Marshal diagnostic checks; native roundtrip passes; exact mkxp UTF8 callback reproduces strict mismatch"
