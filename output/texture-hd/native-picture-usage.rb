# Read production event references without loading player saves.
passed = false
begin
  references = {}
  collect = lambda do |value, context|
    case value
    when String
      references[value] ||= []
      references[value] << context unless references[value].include?(context)
    when Array
      value.each { |entry| collect.call(entry, context) }
    end
  end
  maps = 0
  Dir['Data/Map[0-9]*.rxdata'].sort.each do |path|
    map = load_data(path)
    map.events.each_value do |event|
      event.pages.each do |page|
        page.list.each { |command| collect.call(command.parameters, path) }
      end
    end
    maps += 1
  end
  load_data('Data/CommonEvents.rxdata').compact.each do |event|
    event.list.each { |command| collect.call(command.parameters, "common-event-#{event.id}") }
  end
  File.write('output/texture-hd/p2-evidence/event-resource-references.json', HTTPLite::JSON.stringify(references))
  File.write('output/texture-hd/p2-evidence/event-resource-result.txt', "EVENT_RESOURCE_PASS maps=#{maps} strings=#{references.length}\n")
  passed = true
rescue Exception => error
  File.write('output/texture-hd/p2-evidence/event-resource-result.txt', "EVENT_RESOURCE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}\n")
ensure
  exit!(passed ? 0 : 1)
end
