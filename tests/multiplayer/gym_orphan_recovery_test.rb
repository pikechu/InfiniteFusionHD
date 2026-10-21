require "ostruct"
root = File.expand_path("../..", __dir__)
load File.join(root, "Data/Scripts/054_Multiplayer/001_Client.rb")
class PokeBattle_Battle; end
load File.join(root, "Data/Scripts/054_Multiplayer/005_Gym.rb")
class OrphanGymClient
  attr_reader :profile, :requests
  def initialize
    @profile, @requests = OpenStruct.new(:account => {}), []
    def @profile.save; true; end
    @challenge = {"id" => "gc_" + "a" * 32, "owner_id" => player_id, "status" => "active"}
    @profile.account["last_recovered_operation"] = {"path" => "/v1/rooms", "response" => {"ok" => true, "room" => {"code" => "ABCDEF"}}}
  end
  def player_id; "p_" + "a" * 24; end
  def recover_pending; nil; end
  def request(method, path, body = {})
    @requests << [method, path, body]
    if path == "/v1/gym-challenges"
      {"challenges" => [{"id" => "gc_" + "b" * 32, "owner_id" => "p_foreign", "status" => "active"}, @challenge.dup]}
    elsif method == "GET" && path == "/v1/gym-challenges/" + @challenge["id"]
      {"challenge" => @challenge.dup}
    elsif path == "/v1/gym-challenges/" + @challenge["id"] + "/result"
      @challenge.merge!("status" => "finished", "result" => body.dup)
      {"challenge" => @challenge.dup}
    else
      raise "Unexpected mutation/award/new challenge: #{method} #{path}"
    end
  end
end
checks = 0
verify = lambda { |value, message| raise(message) unless value; checks += 1 }
client = OrphanGymClient.new
session = KIFMultiplayer::GymSession.new(client)
verify.call(session.journal.nil?, "fixture unexpectedly already has a Gym journal")
result = session.recover
verify.call(result && result.dig("challenge", "id") == "gc_" + "a" * 32, "overwritten local receipt orphaned the original server challenge")
verify.call(result.dig("challenge", "result", "outcome") == "abnormal", "interrupted local engine fabricated a win")
verify.call(client.requests.map { |request| request[0] } == %w[GET GET POST], "recovery created another attempt or claimed an unearned medal")
verify.call(client.requests.last[1] == "/v1/gym-challenges/gc_" + "a" * 32 + "/result", "foreign challenge was adopted")
verify.call(session.journal.nil?, "closed interrupted challenge retained its journal")
verify.call(client.profile.account.dig("last_recovered_operation", "path") == "/v1/rooms", "Gym recovery consumed a different feature's receipt")
verify.call(session.recover.nil?, "finished challenge was rediscovered and replayed")
puts "GYM_ORPHAN_RECOVERY_PASS checks=#{checks}"
