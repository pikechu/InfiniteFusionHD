# frozen_string_literal: true
# Audit trusted event scripts without executing them or injecting story flags.
require "ripper"
require_relative "../../server/multiplayer/native/world"
KIFNative.reset
KIFNative.initialize_world
context = Interpreter.new
unknown, syntax_errors = {}, []
unknown_constants = {}
maps, scripts, calls = 0, 0, 0

visit = lambda do |node, location|
  next unless node.is_a?(Array)
  if [:fcall, :vcall].include?(node[0])
    name = node[1][1]
    calls += 1
    unless context.respond_to?(name, true)
      entry = unknown[name] ||= {"count" => 0, "examples" => []}
      entry["count"] += 1
      entry["examples"] << location if entry["examples"].length < 3
    end
  end
  if [:const_ref, :top_const_ref, :const_path_ref].include?(node[0]) || node[0] == :var_ref && node[1].is_a?(Array) && node[1][0] == :@const
    constants = lambda do |part|
      next nil unless part.is_a?(Array)
      next part[1] if part[0] == :@const
      values = part.drop(1).filter_map { |child| constants.call(child) }
      values.empty? ? nil : values.join("::")
    end
    name = constants.call(node)
    if name && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) && !Object.const_defined?(name)
      entry = unknown_constants[name] ||= {"count" => 0, "examples" => []}
      entry["count"] += 1
      entry["examples"] << location if entry["examples"].length < 3
    end
  end
  node.each { |child| visit.call(child, location) if child.is_a?(Array) }
end
audit_list = lambda do |list, location|
  index = 0
  while index < list.length
    if list[index].code == 355
      code = list[index].parameters[0].to_s.dup
      while [355,655].include?(list[index + 1]&.code)
        index += 1
        code += "\n" + list[index].parameters[0].to_s
      end
      scripts += 1
      parsed = Ripper.sexp(code.force_encoding(Encoding::UTF_8))
      parsed ? visit.call(parsed, location) : syntax_errors << location
    end
    index += 1
  end
end
Dir[File.join(KIFNative::ROOT, "Data/Map*.rxdata")].sort.each do |path|
  next unless File.basename(path).match?(/\AMap\d+\.rxdata\z/)
  maps += 1
  map = load_data("Data/" + File.basename(path))
  map.events.each_value do |event|
    event.pages.each_with_index { |page, index| audit_list.call(page.list, {"map" => File.basename(path), "event" => event.id, "page" => index + 1}) }
  end
end
load_data("Data/CommonEvents.rxdata").compact.each do |event|
  audit_list.call(event.list, {"common_event" => event.id})
end
providers = {}
Dir[File.join(KIFNative::ROOT, "Data/Scripts/**/*.rb")].each do |path|
  File.read(path).scan(/^\s*def\s+(?:[A-Za-z_:]+\.)?([A-Za-z_][A-Za-z_0-9!?]*)/).each do |match|
    (providers[match[0]] ||= []) << path.delete_prefix(KIFNative::ROOT + "/Data/Scripts/")
  end
end
unknown.each { |name, value| value["providers"] = providers[name] || [] }
report = {"maps" => maps, "scripts" => scripts, "calls" => calls,
          "unknown" => unknown.sort_by { |name, value| [-value["count"], name] }.to_h, "unknown_constants" => unknown_constants, "syntax_errors" => syntax_errors}
File.write(ARGV.fetch(0), JSON.pretty_generate(report) + "\n")
puts "ORIGINAL_EVENT_DEPENDENCIES maps=#{maps} scripts=#{scripts} unresolved=#{unknown.length} syntax_errors=#{syntax_errors.length}"
raise "Native event audit did not cover the installed world" unless maps > 800 && scripts > 1000 && calls > 1000 && !unknown.key?("pbMessage")
