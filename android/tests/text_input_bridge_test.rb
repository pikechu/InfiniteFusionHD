# Actual pbFreeText and keyboard-window update bodies with a mocked native host.
# The real Android Ruby adapter consumes a latched bridge queue after native update.
# No SDL, JNI, device, assets, player save, or network access is needed.
module System
  class << self
    attr_accessor :android_host
    def is_android?; !!@android_host; end
    def puts(_message); end
  end
end

module Input
  DOWN = 2; LEFT = 4; RIGHT = 6; UP = 8
  B = 12; C = 13
  class << self
    attr_reader :updates, :order, :queries, :text_reads, :text_sets, :get_reads
    attr_accessor :query_results, :setter_result, :setter_error, :before_text_set
    def reset(events = {})
      @events = events; @updates = 0; @physical = {}
      @pending_trigger = {}; @pending_release = {}
      @native_trigger = {}; @native_release = {}; @pending_text = ""
      @order = []; @queries = []; @text_reads = 0; @text_input = false
      @query_results = {}
      @text_sets = []; @setter_result = :native_text_mode_result
      @get_reads = 0
      @setter_error = @before_text_set = nil
    end
    def native_down(code)
      @pending_trigger[code] = true unless @physical[code]
      @physical[code] = true
    end
    def native_up(code)
      @pending_release[code] = true if @physical[code]
      @physical.delete(code)
    end
    def update
      @updates += 1
      @order << :native_update
      (@events[@updates] || []).each do |action, value|
        case action
        when :tap then KIFAndroidBridge.down(value); KIFAndroidBridge.up(value)
        when :down then KIFAndroidBridge.down(value)
        when :up then KIFAndroidBridge.up(value)
        when :physical_down then native_down(value)
        when :physical_up then native_up(value)
        when :text then @pending_text << value
        when :native_mode then @text_input = value
        else raise "Unknown host event #{action.inspect}"
        end
      end
      @native_trigger = @pending_trigger; @pending_trigger = {}
      @native_release = @pending_release; @pending_release = {}
      :native_update_result
    end
    def press?(code); !!@physical[code]; end
    def trigger?(code); !!@native_trigger[code]; end
    def repeat?(code); !!@native_trigger[code]; end
    def release?(code); !!@native_release[code]; end
    def dir4; [2, 4, 6, 8].find { |code| press?(code) } || 0; end
    def dir8; dir4; end
    def native_extended(name, code)
      @queries << [name, code]
      unless code.is_a?(Symbol) || code.is_a?(Integer)
        raise TypeError, "native extended key must be a Symbol or Integer"
      end
      return @query_results[[name, code]] if @query_results.key?([name, code])
      case name
      when :pressex? then !!@physical[code]
      when :triggerex?, :repeatex? then !!@native_trigger[code]
      when :releaseex? then !!@native_release[code]
      end
    end
    def pressex?(code); native_extended(:pressex?, code); end
    def triggerex?(code); native_extended(:triggerex?, code); end
    def repeatex?(code); native_extended(:repeatex?, code); end
    def releaseex?(code); native_extended(:releaseex?, code); end
    def text_input; @text_reads += 1; @text_input; end
    def native_text_mode=(enabled); @text_input = enabled; end
    def text_input=(enabled)
      @text_sets << enabled
      @before_text_set.call(enabled) if @before_text_set
      raise @setter_error if @setter_error
      @text_input = enabled
      @setter_result
    end
    def gets
      @get_reads += 1
      result = @pending_text
      @pending_text = ""
      result
    end
  end
  reset
end

module KIFAndroidBridge
  class << self
    def clear; @pressed = @triggered = @released = 0; end
    def down(code)
      bit = 1 << code
      @triggered |= bit if (@pressed & bit) == 0
      @pressed |= bit
    end
    def up(code)
      bit = 1 << code
      @released |= bit if (@pressed & bit) != 0
      @pressed &= ~bit
    end
    def input_poll
      Input.order << :bridge_poll
      result = [@pressed, @triggered, @released]
      @triggered = @released = 0
      result
    end
  end
  clear
end

class FrameBudgetExceeded < StandardError; end
module Graphics
  class << self
    attr_reader :updates
    def reset(limit); @updates = 0; @limit = limit; end
    def update
      @updates += 1
      raise FrameBudgetExceeded, "text entry did not accept confirmation/cancellation" if @updates > @limit
    end
  end
end

# Rendering is replaced; the actual helper and window edit methods below still
# enforce cursor, Unicode length, password behavior, and refresh after insertion.
class Window_TextEntry
  class << self
    def instances; @instances ||= []; end
  end
  attr_accessor :visible, :z, :active
  attr_reader :helper, :disposed, :refreshes
  def initialize(text, *_geometry)
    self.class.instances << self
    @frame = 0; @active = true
    @helper = CharacterEntryHelper.new(text)
    self.text = text
  end
  def refresh; @refreshes = (@refreshes || 0) + 1; end
  def dispose; @disposed = true; end
end
def pbPositionNearMsgWindow(*_args); end

root = File.expand_path("../..", __dir__)
messages_path = ARGV[1] || File.join(root, "Data/Scripts/007_Objects and windows/011_Messages.rb")
keyboard_path = File.join(root, "Data/Scripts/007_Objects and windows/012_TextEntry.rb")
messages_source = File.read(messages_path, :encoding => "UTF-8")
keyboard_source = File.read(keyboard_path, :encoding => "UTF-8")
helper = keyboard_source.match(/^class CharacterEntryHelper\r?\n.*?^end\r?$/m) or raise "character helper source boundary missing"
window_source = keyboard_source.match(/^class Window_TextEntry < SpriteWindow_Base\r?\n.*?^end\r?$/m) or raise "text window source boundary missing"
window_edits = window_source[0].match(/^  def text\r?\n.*?(?=^  def update\r?\n)/m) or raise "text window edit methods missing"
free_text = messages_source.match(/^def pbFreeText\(.*?^end\r?$/m) or raise "pbFreeText source boundary missing"
keyboard = keyboard_source.match(/^class Window_TextEntry_Keyboard < Window_TextEntry\r?\n.*?^end\r?$/m) or raise "keyboard update source boundary missing"
Object.class_eval(free_text[0], messages_path, messages_source[0...free_text.begin(0)].count("\n") + 1)
Object.class_eval(helper[0], keyboard_path, keyboard_source[0...helper.begin(0)].count("\n") + 1)
Window_TextEntry.class_eval(window_edits[0], keyboard_path, keyboard_source[0...window_source.begin(0)].count("\n") + window_source[0][0...window_edits.begin(0)].count("\n") + 1)
Object.class_eval(keyboard[0], keyboard_path, keyboard_source[0...keyboard.begin(0)].count("\n") + 1)
load File.join(root, "Data/Scripts/000_Platform.rb")
load(ARGV[0] || File.join(root, "android/ruby/kif_android_input.rb"))

checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
extended = [:pressex?, :triggerex?, :repeatex?, :releaseex?]
native_extended = extended.map { |name| [name, Input.method(name)] }.to_h
native_setter = Input.method(:text_input=)
old_flag = ENV["KIF_ANDROID_INPUT"]
begin
  ENV["KIF_ANDROID_INPUT"] = "1"
  KIF::Platform.instance_variable_set(:@android_input_bridge_loaded, true)
  System.android_host = false
  desktop_methods = (extended + [:update, :press?, :trigger?, :repeat?, :release?, :dir4, :dir8, :text_input, :text_input=]).map { |name| [name, Input.method(name)] }.to_h
  assert.call(KIF::Platform.install_input_bridge == false, "Windows installed Android input bridge")
  assert.call(desktop_methods.all? { |name, method| Input.method(name) == method }, "Windows Input methods changed")
  Input.update
  assert.call(Input.order == [:native_update], "Windows polled the Android bridge")

  System.android_host = true
  backend = KIF::AndroidInputBackend.install(Input, KIFAndroidBridge)
  wrappers = extended.map { |name| [name, Input.method(name)] }.to_h
  reset = lambda do |events = {}, limit = 10|
    KIFAndroidBridge.clear; Input.reset; Input.text_input = false; Input.update
    Input.reset(events); Graphics.reset(limit)
    Window_TextEntry_Keyboard.instances.clear
  end

  # Recreate the old adapter's unwrapped extended path, leaving the actual
  # standard virtual-key wrappers and update/poll loop installed. Both touch
  # edges reach Input.trigger? but the unchanged pbFreeText cannot exit.
  native_extended.each { |name, method| Input.define_singleton_method(name, method) }
  reset.call({ 1 => [[:text, "-edited"]], 2 => [[:tap, Input::C]], 3 => [[:tap, Input::B]] }, 4)
  old_edges = []
  timed_out = false
  begin
    pbFreeText(nil, "original", false, 32) do
      old_edges << [Input.trigger?(Input::C), Input.trigger?(Input::B)]
    end
  rescue FrameBudgetExceeded
    timed_out = true
  ensure
    wrappers.each { |name, method| Input.define_singleton_method(name, method) }
    Input.text_input = false
  end
  assert.call(timed_out && old_edges.include?([true, false]) && old_edges.include?([false, true]), "old extended path unexpectedly accepted virtual C/X")
  assert.call(!native_extended.fetch(:triggerex?).call(:RETURN) && !native_extended.fetch(:triggerex?).call(:ESCAPE) && Window_TextEntry_Keyboard.instances.last.text == "original-edited", "old-path comparison did not retain native text without physical Return/Escape")

  reset.call({ 1 => [[:text, "-edited"]], 2 => [[:tap, Input::C]], 5 => [[:tap, Input::C]] })
  result = pbFreeText(nil, "original", true, 32)
  window = Window_TextEntry_Keyboard.instances.last
  assert.call(result == "original-edited", "short virtual C did not return the complete native-entered text")
  assert.call(window.passwordChar == "*" && window.disposed && Input.text_input == false, "confirmation skipped password/dispose/text-mode cleanup")
  assert.call(Input.updates == 3 && Input.order == [:native_update, :bridge_poll] * 3, "pbFreeText changed native-update/poll ordering or cleanup update")
  assert.call(!Input.triggerex?(:RETURN) && !Input.releaseex?(:RETURN) && !Input.trigger?(Input::C), "confirmation edge leaked after cleanup")
  assert.call(pbFreeText(nil, "next", false, 32) == "next" && Input.updates == 6, "a second text dialog accepted a stale confirm edge instead of waiting for a fresh tap")

  reset.call({ 1 => [[:text, "-discarded"]], 2 => [[:tap, Input::B]] })
  result = pbFreeText(nil, "original", false, 32)
  assert.call(result == "original" && Window_TextEntry_Keyboard.instances.last.text == "original-discarded", "virtual X/B did not preserve the original value")
  assert.call(Window_TextEntry_Keyboard.instances.last.disposed && !Input.text_input, "cancellation skipped cleanup")

  reset.call({ 1 => [[:tap, Input::LEFT]], 2 => [[:text, "X"]], 3 => [[:tap, Input::C]] })
  assert.call(pbFreeText(nil, "abc", false, 12) == "abXc", "real keyboard-window update did not move the cursor before native text insertion")

  reset.call({ 1 => [[:text, "-physical"]], 2 => [[:physical_down, :RETURN]] })
  assert.call(pbFreeText(nil, "original", false, 32) == "original-physical", "physical Return no longer confirms")
  reset.call({ 1 => [[:text, "-physical"]], 2 => [[:physical_down, :ESCAPE]] })
  assert.call(pbFreeText(nil, "original", false, 32) == "original", "physical Escape no longer cancels")

  [false, true].each do |mode|
    reset.call
    Input.text_input = mode
    Input.native_down(:RETURN); Input.update
    assert.call(Input.pressex?(:RETURN) && Input.triggerex?(:RETURN) && Input.repeatex?(:RETURN), "text mode #{mode} erased physical press/trigger/repeat")
    KIFAndroidBridge.down(Input::C); Input.update
    KIFAndroidBridge.up(Input::C); Input.update
    assert.call(Input.pressex?(:RETURN), "text mode #{mode} touch release erased held physical Return")
    Input.native_up(:RETURN); Input.update
    assert.call(Input.releaseex?(:RETURN) && !Input.pressex?(:RETURN), "text mode #{mode} erased physical release")
  end

  { :RETURN => Input::C, :ESCAPE => Input::B, :LEFT => Input::LEFT,
    :RIGHT => Input::RIGHT, :UP => Input::UP, :DOWN => Input::DOWN }.each do |symbol, code|
    reset.call
    Input.text_input = true
    KIFAndroidBridge.down(code); Input.update
    assert.call(Input.pressex?(symbol) && Input.triggerex?(symbol) && Input.repeatex?(symbol) && !Input.releaseex?(symbol), "#{symbol} did not share virtual down/trigger/repeat")
    Input.update
    assert.call(Input.pressex?(symbol) && !Input.triggerex?(symbol) && !Input.repeatex?(symbol), "#{symbol} retriggered while held")
    KIFAndroidBridge.up(code); Input.update
    assert.call(!Input.pressex?(symbol) && Input.releaseex?(symbol), "#{symbol} did not release")
    Input.update
    assert.call(!Input.triggerex?(symbol) && !Input.repeatex?(symbol) && !Input.releaseex?(symbol), "#{symbol} kept an edge after another poll")
  end

  reset.call
  Input.text_input = true
  KIFAndroidBridge.down(Input::LEFT); Input.update
  22.times { Input.update; assert.call(!Input.repeatex?(:LEFT), "extended arrow repeated before held count 23") }
  Input.update
  assert.call(Input.repeatex?(:LEFT), "extended arrow missed held count 23 repeat")
  5.times { Input.update; assert.call(!Input.repeatex?(:LEFT), "extended arrow repeated before six updates") }
  Input.update
  assert.call(Input.repeatex?(:LEFT), "extended arrow missed six-update repeat")
  KIFAndroidBridge.clear; Input.update
  assert.call(!Input.pressex?(:LEFT) && !Input.repeatex?(:LEFT), "bridge clear left extended arrow stuck")

  reset.call
  [Input::C, Input::B, Input::LEFT].each { |code| KIFAndroidBridge.down(code) }
  Input.update
  [:RETURN, :ESCAPE, :LEFT].each do |symbol|
    assert.call(extended.none? { |name| Input.public_send(name, symbol) }, "disabled text mode mapped #{symbol}")
  end
  assert.call(Input.trigger?(Input::C) && Input.trigger?(Input::B), "normal RGSS buttons changed outside text mode")
  Input.text_input = 1
  assert.call(!Input.triggerex?(:RETURN), "non-boolean text mode enabled virtual mapping")
  Input.text_input = true
  [13, 12, 4, 40, 999, :C, :UNKNOWN, :BACKSPACE].each do |code|
    reads = Input.text_reads
    assert.call(extended.none? { |name| Input.public_send(name, code) } && Input.text_reads == reads, "unknown/integer key #{code.inspect} was remapped")
  end
  native_value = Object.new
  Input.query_results[[:triggerex?, :RETURN]] = native_value
  reads = Input.text_reads
  assert.call(Input.triggerex?(:RETURN).equal?(native_value) && Input.text_reads == reads, "native truthy result did not take precedence")
  Input.query_results[[:triggerex?, :UNKNOWN]] = nil
  assert.call(Input.triggerex?(:UNKNOWN).nil?, "unmapped native nil result changed")
  Input.query_results.clear
  extended.each do |name|
    [[], [:RETURN, :ESCAPE], ["RETURN"], [nil]].each do |arguments|
      native_error = wrapped_error = nil
      begin; native_extended.fetch(name).call(*arguments); rescue StandardError => error; native_error = [error.class, error.message]; end
      begin; Input.public_send(name, *arguments); rescue StandardError => error; wrapped_error = [error.class, error.message]; end
      assert.call(native_error && native_error == wrapped_error, "#{name} changed native argument/error behavior for #{arguments.inspect}")
    end
  end

  # Hiding the IME may stop native text events without ending pbFreeText. Keep
  # the real dialog and keyboard bodies, and change only the mocked native mode.
  reset.call({ 1 => [[:text, "-entered"]], 2 => [[:native_mode, false]],
               3 => [[:tap, Input::C]] }, 5)
  hidden_modes = []
  hidden_result = nil
  hidden_timeout = false
  begin
    hidden_result = pbFreeText(nil, "original", false, 32) do
      hidden_modes << [Input.text_input, Window_TextEntry_Keyboard.instances.last.text]
    end
  rescue FrameBudgetExceeded
    hidden_timeout = true
  ensure
    Input.text_input = false
  end
  assert.call(!hidden_timeout && hidden_result == "original-entered", "native mode loss trapped the real pbFreeText after virtual C")
  assert.call(hidden_modes.include?([false, "original-entered"]), "text-session tracking changed the public native getter or bypassed the real keyboard")
  assert.call(Window_TextEntry_Keyboard.instances.last.disposed && !Input.triggerex?(:RETURN), "hidden-IME confirmation left a window or stale Return")

  reset.call({ 1 => [[:text, "-discarded"]], 2 => [[:native_mode, false]],
               3 => [[:tap, Input::B]] })
  assert.call(pbFreeText(nil, "original", false, 32) == "original", "native mode loss trapped the real pbFreeText after virtual X")
  assert.call(Window_TextEntry_Keyboard.instances.last.text == "original-discarded" &&
              Window_TextEntry_Keyboard.instances.last.disposed && Input.text_sets == [true, false], "hidden-IME cancellation changed original/dispose/session cleanup")

  reset.call
  Input.text_input = false
  Input.native_text_mode = true # SDL stop request has not taken effect yet.
  [Input::C, Input::B, Input::LEFT].each { |code| KIFAndroidBridge.down(code) }
  Input.update
  assert.call(Input.text_input == true, "session stop falsified the public native getter")
  assert.call([:RETURN, :ESCAPE, :LEFT].all? { |symbol| extended.none? { |name| Input.public_send(name, symbol) } }, "native getter lag enabled virtual text keys after explicit false")
  assert.call(Input.trigger?(Input::C) && Input.trigger?(Input::B), "session stop cleared ordinary game buttons")
  Input.native_down(:RETURN); Input.update
  assert.call(Input.triggerex?(:RETURN), "explicit false suppressed a physical Return")

  # State is recorded only after the original setter succeeds. Its actual
  # return is checked with public_send; Ruby assignment itself returns its RHS.
  reset.call
  KIFAndroidBridge.down(Input::C); Input.update
  native_observations = []
  Input.before_text_set = lambda { |_value| native_observations << Input.triggerex?(:RETURN) }
  marker = Object.new
  Input.setter_result = marker
  assert.call(Input.public_send(:text_input=, true).equal?(marker), "wrapped setter replaced the native return object")
  assert.call(native_observations == [false], "session state changed before native setter ran")
  Input.before_text_set = nil
  Input.native_text_mode = false
  assert.call(Input.text_input == false && Input.triggerex?(:RETURN), "explicit true did not own the virtual session while getter was false")
  Input.setter_result = false
  assert.call(Input.public_send(:text_input=, true) == false && Input.triggerex?(:RETURN), "false native return prevented a successful explicit true request")
  Input.setter_result = nil
  assert.call(Input.public_send(:text_input=, true).nil? && Input.triggerex?(:RETURN), "nil native return prevented a successful repeated true request")

  failure = IOError.new("native text-mode failure")
  Input.native_text_mode = false
  Input.setter_error = failure
  observed_failure = nil
  begin; Input.public_send(:text_input=, false); rescue StandardError => error; observed_failure = error; end
  assert.call(observed_failure.equal?(failure) && Input.triggerex?(:RETURN), "failed native false request changed the session or exception object")
  Input.setter_error = nil
  Input.text_input = false
  Input.native_text_mode = true
  Input.setter_error = failure
  observed_failure = nil
  begin; Input.public_send(:text_input=, true); rescue StandardError => error; observed_failure = error; end
  assert.call(observed_failure.equal?(failure) && !Input.triggerex?(:RETURN), "failed native true request reopened the ended session")
  Input.setter_error = nil
  [[], [true, false]].each do |arguments|
    native_error = wrapped_error = nil
    begin; native_setter.call(*arguments); rescue StandardError => error; native_error = [error.class, error.message]; end
    begin; Input.public_send(:text_input=, *arguments); rescue StandardError => error; wrapped_error = [error.class, error.message]; end
    assert.call(native_error && native_error == wrapped_error && !Input.triggerex?(:RETURN), "setter arity failure changed native error or ended session")
  end

  # Accepting a non-boolean native value relinquishes the explicit override;
  # it must neither inherit old true/false nor treat a truthy object as true.
  [nil, 1, :accepted_native_value, Object.new].each do |value|
    Input.text_input = true
    result = Input.public_send(:text_input=, value)
    assert.call(result.nil? && Input.text_input.equal?(value), "accepted non-boolean request changed native value/return")
    Input.native_text_mode = false
    assert.call(!Input.triggerex?(:RETURN), "accepted non-boolean request retained an old true session")
    Input.text_input = false
    Input.public_send(:text_input=, value)
    Input.native_text_mode = true
    assert.call(Input.triggerex?(:RETURN), "accepted non-boolean request retained an old false session instead of native fallback")
  end

  reset.call
  Input.text_input = true
  Input.native_text_mode = false
  poll = KIFAndroidBridge.method(:input_poll)
  begin
    KIFAndroidBridge.define_singleton_method(:input_poll) { raise IOError, "transient poll failure" }
    Input.update
    assert.call(!Input.triggerex?(:RETURN) && !Input.pressex?(:RETURN), "poll error fabricated a text edge")
  ensure
    KIFAndroidBridge.define_singleton_method(:input_poll, poll)
  end
  KIFAndroidBridge.clear
  KIFAndroidBridge.down(Input::C); KIFAndroidBridge.up(Input::C); Input.update
  assert.call(Input.text_input == false && Input.triggerex?(:RETURN), "poll failure erased the still-open Ruby text session")
  Input.update
  assert.call(!Input.triggerex?(:RETURN), "session mode fabricated a new edge without a touch")

  # Flush a final native IME commit before Return reads window.text. These
  # scenarios use the actual CharacterEntryHelper and Window_TextEntry edits.
  final_text = "-last\u4E2D\u{1F31F}"
  reset.call({ 1 => [[:text, final_text], [:tap, Input::C]] })
  final_result = pbFreeText(nil, "base", true, 32)
  final_window = Window_TextEntry_Keyboard.instances.last
  assert.call(final_result == "base" + final_text, "same-frame final IME text was lost before virtual C returned")
  assert.call(Input.get_reads == 1 && Input.gets.empty?, "same-frame confirmation did not consume the native text exactly once")
  assert.call(final_window.helper.cursor == final_result.length && final_window.refreshes >= final_text.length &&
              final_window.passwordChar == "*" && final_window.disposed, "final commit bypassed actual cursor/refresh/password/dispose behavior")

  reset.call({ 1 => [[:text, "\u4E2D\u{1F31F}Z"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "AB", false, 4) == "AB\u4E2D\u{1F31F}", "same-frame commit bypassed Unicode character maxlength")
  assert.call(Window_TextEntry_Keyboard.instances.last.helper.cursor == 4 && Input.gets.empty?, "maxlength rejection left a cursor error or text for the next dialog")
  reset.call({ 1 => [[:text, "extra"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "full", false, 4) == "full", "same-frame commit exceeded an already full field")
  reset.call({ 1 => [[:text, "extra"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "", false, 0) == "", "same-frame commit ignored zero maxlength")
  reset.call({ 1 => [[:text, "unlimited"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "", false, -1) == "unlimited", "final commit changed the actual helper's unlimited length")

  reset.call({ 1 => [[:tap, Input::LEFT]],
               2 => [[:text, "\u4E2D\u{1F31F}"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "abc", false, 12) == "ab\u4E2D\u{1F31F}c" &&
              Window_TextEntry_Keyboard.instances.last.helper.cursor == 4, "final commit ignored the actual keyboard's caret position")

  reset.call({ 1 => [[:text, "EBASE\n"], [:physical_down, :RETURN]] })
  assert.call(pbFreeText(nil, "", false, 32) == "EBASE", "IME Return committed a newline into the single-line field")
  reset.call({ 1 => [[:text, "A\r\n\u4E2DB\n"], [:tap, Input::C]] })
  assert.call(pbFreeText(nil, "", false, 32) == "A\u4E2DB", "IME CR/LF filtering discarded printable Unicode or kept control newlines")

  reset.call({ 1 => [[:text, "-discarded"], [:tap, Input::B]], 4 => [[:tap, Input::C]] })
  assert.call(pbFreeText(nil, "original", false, 32) == "original" &&
              Window_TextEntry_Keyboard.instances.last.text == "original" && Input.get_reads == 1, "same-frame cancellation inserted or failed to discard pending text")
  assert.call(pbFreeText(nil, "next", false, 32) == "next", "cancelled pending text leaked into the next real dialog")
  reset.call({ 1 => [[:text, "-discarded"], [:tap, Input::C], [:tap, Input::B]] })
  assert.call(pbFreeText(nil, "original", false, 32) == "original" && Input.gets.empty?, "simultaneous confirm/cancel changed Escape priority or left pending text")

  begin
    System.android_host = false
    [[:RETURN, :confirm], [:ESCAPE, :cancel]].each do |key, label|
      reset.call({ 1 => [[:text, "-desktop-pending"], [:physical_down, key]] })
      assert.call(pbFreeText(nil, "desktop", false, 32) == "desktop" && Input.get_reads == 0, "Windows #{label} changed text or read the pending native queue")
      assert.call(Input.gets == "-desktop-pending", "Windows #{label} drained text despite platform guard")
    end
    reads = Input.get_reads
    KIF::Platform.finish_text_entry(Object.new, true)
    assert.call(Input.get_reads == reads, "Windows platform hook read text or touched the window")
  ensure
    System.android_host = true
  end

  # Later Mods can alias extended methods and either mode accessor. Captured
  # Methods keep the bridge rooted in the originals rather than these aliases.
  class << Input
    alias_method :later_triggerex, :triggerex?
    alias_method :later_text_input, :text_input
    alias_method :later_text_input_set, :text_input=
    def triggerex?(code); later_triggerex(code); end
    def text_input; later_text_input; end
    def text_input=(value); later_text_input_set(value); end
  end
  later_wrapper = Input.method(:triggerex?)
  later_setter = Input.method(:text_input=)
  Input.text_input = true
  Input.native_text_mode = false
  KIFAndroidBridge.down(Input::C); KIFAndroidBridge.up(Input::C); Input.update
  assert.call(Input.triggerex?(:RETURN), "later extended/getter aliases recursed or lost virtual confirm")
  assert.call(KIF::AndroidInputBackend.install(Input, KIFAndroidBridge).equal?(backend) && Input.method(:triggerex?) == later_wrapper && Input.method(:text_input=) == later_setter, "duplicate install changed a later extended/setter alias")
  KIFAndroidBridge.clear; Input.update
  assert.call(!Input.triggerex?(:RETURN) && !Input.pressex?(:RETURN), "extended alias retained stale touch state")

  # Missing runtime capabilities must leave those existing interfaces untouched.
  no_getter = Module.new
  [:update, :press?, :trigger?, :repeat?, :dir4, :dir8, :triggerex?].each do |name|
    no_getter.define_singleton_method(name) { |*_args| false }
  end
  no_getter.define_singleton_method(:text_input=) { |value| value }
  before = no_getter.method(:triggerex?)
  before_setter = no_getter.method(:text_input=)
  KIF::AndroidInputBackend.install(no_getter, KIFAndroidBridge)
  assert.call(no_getter.method(:triggerex?) == before && no_getter.method(:text_input=) == before_setter && !no_getter.respond_to?(:text_input), "runtime without text_input getter hooked extended input or mode accessors")
  partial = Module.new
  [:update, :press?, :trigger?, :repeat?, :dir4, :dir8].each do |name|
    partial.define_singleton_method(name) { |*_args| false }
  end
  partial.define_singleton_method(:text_input) { true }
  partial.define_singleton_method(:triggerex?) { |_code| false }
  KIF::AndroidInputBackend.install(partial, KIFAndroidBridge)
  assert.call(!partial.respond_to?(:pressex?) && !partial.respond_to?(:repeatex?) && !partial.respond_to?(:releaseex?) && !partial.respond_to?(:text_input=) && partial.triggerex?(:RETURN) == false, "partial runtime gained unsupported extended or setter interfaces")
  KIFAndroidBridge.down(Input::C); KIFAndroidBridge.up(Input::C); partial.update
  assert.call(partial.triggerex?(:RETURN), "getter-only runtime lost its original native-mode fallback")

  puts "PASS: #{checks} Android text-input bridge assertions (real text dialog/helper/edits; native-mode loss, final commits, Windows passthrough)"
ensure
  ENV["KIF_ANDROID_INPUT"] = old_flag
end
