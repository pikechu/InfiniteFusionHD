begin
  load "scripts/multiplayer/runtime-preload.rb"
  output = []
  %w[socket openssl io/wait fcntl timeout].each do |library|
    begin
      require library
      output << "require #{library} AVAILABLE"
    rescue LoadError => error
      output << "require #{library} UNAVAILABLE #{error.message}"
    end
  end
  socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
  output << "Socket methods=#{socket.methods.grep(/connect|read|write|wait|recv|send|nonblock/).sort.inspect}"
  output << "Socket private=#{socket.private_methods.grep(/connect|read|write|wait|recv|send|nonblock/).sort.inspect}"
  output << "Socket class=#{Socket.methods.grep(/tcp|addr|connect/).sort.inspect}"
  socket.close
  File.write(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "socket-capabilities.log"), output.join("\n"))
rescue Exception => error
  STDERR.puts("SOCKET_CAPABILITIES_FAIL #{error.class}: #{error.message}")
ensure
  exit!
end
