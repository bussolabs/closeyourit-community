# frozen_string_literal: true

require "socket"

# CYRA-807 — Un server HTTP vero sul loopback, per misurare quanto di una risposta viene DAVVERO
# scaricato.
#
# PERCHÉ NON BASTA WEBMOCK: lo stub consegna il corpo in un colpo solo, quindi «ho letto tutti i
# megabyte e poi ho tagliato» e «ho smesso di leggere al tetto» producono lo stesso risultato — è
# esattamente la distinzione che serviva provare. Qui la risposta DICHIARA un corpo enorme, ne manda
# solo la testa e poi tace: chi legge fino in fondo resta appeso fino al timeout, chi si ferma al
# tetto torna subito col corpo tagliato. La differenza è l'esito della prova, non una soglia di byte
# da indovinare (i buffer del kernel renderebbero quella soglia un dado).
#
# Una connessione per risposta configurata, nell'ordine: il fetcher chiude e riapre a ogni salto
# della catena di redirect, quindi la sequenza è deterministica.
class StreamingBodyServer
  # Quanto si aspetta che il client chiuda, dopo aver mandato la testa del corpo. Nel caso buono
  # chiude subito; questo tetto serve solo a non lasciare un thread appeso se la prova fallisce.
  CLOSE_WAIT = 5

  def initialize(responses)
    @responses = Array(responses)
    @server = TCPServer.new("127.0.0.1", 0)
    @closed_by_client = []
  end

  def port = @server.addr[1]

  def start
    @thread = Thread.new do
      @responses.each { |spec| serve(@server.accept, spec) }
    rescue IOError, Errno::EBADF
      nil # il server è stato chiuso a fine prova mentre aspettava una connessione
    end
    self
  end

  # true se il client ha chiuso la connessione senza aspettare i byte che la risposta gli aveva
  # promesso: è la prova che la lettura si è interrotta e il socket è stato liberato.
  def client_closed_early?
    @thread&.join(CLOSE_WAIT + 1)
    @closed_by_client.last
  end

  def stop
    @thread&.kill
    @server.close unless @server.closed?
  end

  private

  def serve(socket, spec)
    read_request(socket)
    write_head(socket, spec)
    write_body(socket, spec[:body].to_s)
    @closed_by_client << wait_for_close(socket)
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    while (line = socket.gets)
      break if line == "\r\n"
    end
  end

  def write_head(socket, spec)
    body = spec[:body].to_s
    headers = { "Content-Length" => (spec[:declared_length] || body.bytesize).to_s,
                "Connection" => "close" }.merge(spec[:headers] || {})
    socket.write("HTTP/1.1 #{spec[:status] || '200 OK'}\r\n")
    headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
    socket.write("\r\n")
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  end

  def write_body(socket, body)
    return if body.empty?

    socket.write(body)
    socket.flush
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil # il client si è già fermato: è il caso che stiamo provando
  end

  # Il socket diventa leggibile anche quando dall'altra parte non c'è più nessuno: la lettura
  # risponde con la fine del flusso invece che con dei byte.
  def wait_for_close(socket)
    return false if IO.select([ socket ], nil, nil, CLOSE_WAIT).nil?

    socket.read_nonblock(1)
    false
  rescue EOFError, Errno::ECONNRESET
    true
  rescue IO::WaitReadable
    false
  end
end
