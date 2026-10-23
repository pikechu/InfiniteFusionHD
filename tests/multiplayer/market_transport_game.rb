begin
  load 'scripts/multiplayer/test-bootstrap.rb'
  module KIFMultiplayer
    class SocketHTTP
      alias_method :market_trace_protocol_error,:protocol_error
      def protocol_error(message)
        KIFMultiplayerFeatureTest.log('HTTP_FRAME_ERROR '+message)
        market_trace_protocol_error(message)
      end
    end
  end
  client=KIFMultiplayer::Client.new
  80.times do |index|
    result=client.raw_request('GET','/probe/'+(index%4).to_s)
    expected=[0,1,20,80][index%4]
    KIFMultiplayerFeatureTest.check(result['value'].is_a?(Array) && result['value'].length==expected && result['value'].all? { |value| value=='汉字测试'*128 },"HTTP framing request #{index}")
  end
  client.raw_request('POST','/fixture/guest-pass',{'passed'=>true})
rescue Exception=>error
  File.write(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'market-extension-error.log'),"#{error.class}: #{error.message}\n#{error.respond_to?(:details) ? error.details.inspect : ''}\n#{(error.backtrace || []).join("\n")}")
ensure
  exit!(0)
end
