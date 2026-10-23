# Route through this game's real interpreter accessor and command grouping.
ENV['KIF_TRADE_FIXTURES_ONLY']='1'
load File.expand_path('trade_test.rb',__dir__)
module KIFMultiplayer
  module Mainline
    class << self
      attr_accessor :test_active,:last_params
      def active?;@test_active;end
      def projecting?;false;end
      def battle(params);@last_params=params;1;end
    end
  end
end
def pbMapInterpreter; $story_interpreter;end
def pbMapInterpreterRunning?;true;end
def pbWildBattleCore(*args);:legacy;end
load 'Data/Scripts/054_Multiplayer/028_MainlineStory.rb'
KIFMultiplayer::Mainline.define_singleton_method(:finish_field_battle) { |decision| decision }
StoryCommand=Struct.new(:code,:parameters)
StoryPage=Struct.new(:list)
StoryEvent=Struct.new(:pages)
StoryMap=Struct.new(:map_id,:events)
page0=StoryPage.new([StoryCommand.new(0,[])]);page1=StoryPage.new([])
event=Object.new;event.instance_variable_set(:@event,StoryEvent.new([page0,page1]));event.instance_variable_set(:@page,page1)
$game_map=StoryMap.new(240,{14=>event})
$story_interpreter=Object.new
$story_interpreter.instance_variable_set(:@event_id,14)
$story_interpreter.instance_variable_set(:@index,7)
$story_interpreter.instance_variable_set(:@list,[])
KIFMultiplayer::Mainline.test_active=true
checks=0
assert=lambda { |value,name| raise "STORY_CLIENT_FAIL #{name}" unless value;checks+=1;puts "PASS #{name}" }
context=KIFMultiplayer::Mainline.story_context
assert.call(context=={'event_id'=>14,'page'=>1,'command_index'=>7,'occurrence'=>0},'story uses pbMapInterpreter when Game_Map has no interpreter method')
assert.call(KIFMultiplayer::Mainline.story_context['occurrence']==1,'consecutive encounters in one script retain separate occurrence')
$story_interpreter.instance_variable_set(:@index,8)
assert.call(KIFMultiplayer::Mainline.story_context['occurrence']==0,'a different installed command resets occurrence')
$story_interpreter.instance_variable_set(:@index,10)
$story_interpreter.instance_variable_set(:@child_interpreter,Object.new)
list=Array.new(11) { StoryCommand.new(0,[]) };list[9]=StoryCommand.new(117,[2]);$story_interpreter.instance_variable_set(:@list,list)
assert.call(KIFMultiplayer::Mainline.story_context['command_index']==9,'common event links back to its parent map declaration')
$story_interpreter.instance_variable_set(:@child_interpreter,nil)
pbWildBattleCore(Object.new,100)
assert.call(KIFMultiplayer::Mainline.last_params['kind']=='story' && !KIFMultiplayer::Mainline.last_params.key?('pokemon'),'client Pokemon attributes never authorize a story opponent')
KIFMultiplayer::Mainline.test_active=false
assert.call(pbWildBattleCore(:PIKACHU,5)==:legacy,'casual battle routing stays intact')

module KIFServerEngine
  def self.registered(_type,value);value.to_sym;end
end
class StoryPokemon
  attr_accessor :species,:level
  def initialize(species,level,*args);@species,@level=species,level;end
end
original_pokemon=defined?(Pokemon) ? Pokemon : nil
Object.send(:remove_const,:Pokemon) if original_pokemon
Pokemon=StoryPokemon
load 'server/multiplayer/native_story.rb'
commands=[StoryCommand.new(355,['pbWildBattle(:CATERPIE,5)']),StoryCommand.new(355,['pbWildBattle(:WEEDLE,6)']),StoryCommand.new(0,[])]
resolver=KIFServerStory::Resolver.new([]);resolver.commands(commands)
assert.call(resolver.battles.length==2 && resolver.battles.all? { |value| value['command_index']==1 },'adjacent 355 commands share the same end index as Interpreter#command_355')
assert.call(resolver.battles.map { |value| value['foes'][0].species }==[:CATERPIE,:WEEDLE],'merged script grouping preserves each opponent declaration')
parts=KIFServerStory.split('[:A,:B],Pokemon.new(:C,10),"x,y"')
assert.call(parts.length==3,'nested arrays and strings do not split into executable fragments')
begin
  resolver.value('Kernel.system("unexpected")')
  raise 'Unsafe installed expression accepted'
rescue KIFServerStory::Unsupported
  assert.call(true,'unsupported method dispatch is never evaluated')
end
Object.send(:remove_const,:Pokemon)
Pokemon=original_pokemon if original_pokemon
puts "MAINLINE_STORY_CLIENT_TEST_PASS checks=#{checks}"
