# frozen_string_literal: true

require "net/http"
require "uri"
require "socket"
require "resolv"
require "ipaddr"

module Uptime
  # Esegue un singolo check del monitor e ritorna un Result immutabile con esito up/down,
  # response_time_ms ed error. NON tocca il DB. Il tipo di check (CYRA-151) decide il protocollo:
  #   http → richiesta HTTP (status == expected_status, keyword, scadenza cert)
  #   tcp  → connessione TCP a host:porta (porta aperta)
  #   dns  → l'host risolve almeno un indirizzo
  #   ping → l'host risponde all'ICMP echo
  #
  # SICUREZZA (SSRF): host/URL sono dato utente → prima di aprire una connessione (http/tcp/ping) si
  # risolve l'host UNA volta e si RIFIUTANO gli indirizzi privati/loopback/link-local/metadata, pinnando
  # l'IP validato sulla connessione (anti DNS-rebinding). Il DNS check non apre connessioni: risolve e basta.
  class Ping < ApplicationService
    Result = Data.define(:up, :status_code, :response_time_ms, :error, :ssl_expires_at) do
      # ssl_expires_at è presente solo sui ping https andati a segno (not_after del certificato).
      def initialize(up:, status_code:, response_time_ms:, error:, ssl_expires_at: nil)
        super
      end
    end

    METHODS = { "GET" => Net::HTTP::Get, "HEAD" => Net::HTTP::Head, "POST" => Net::HTTP::Post }.freeze

    # ICMP echo (RFC 792): request type 8, reply type 0. Con un socket datagram unprivileged il messaggio
    # ricevuto NON porta l'header IP (a differenza del raw socket), quindi il primo byte è già il type ICMP.
    ICMP_ECHO_REQUEST = 8
    ICMP_ECHO_REPLY = 0
    # ICMPv6 echo (RFC 4443): request type 128, reply type 129. Il checksum (con pseudo-header) lo calcola
    # sempre il kernel, e il messaggio ricevuto non porta mai l'header IPv6 (CYRA-1239).
    ICMPV6_ECHO_REQUEST = 128
    ICMPV6_ECHO_REPLY = 129

    # Il server non ha stack o rotta IPv6: il check non è eseguibile da qui. L'esito lo dice con un motivo
    # dedicato (ipv6_unavailable), così non sembra un guasto del servizio monitorato.
    IPV6_UNAVAILABLE_ERRORS = [
      Errno::EAFNOSUPPORT, Errno::EPROTONOSUPPORT, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL
    ].freeze

    def initialize(monitor:)
      @monitor = monitor
    end

    def call
      case @monitor.check_type.to_sym
      when :http then http_check
      when :tcp then tcp_check
      when :dns then dns_check
      when :ping then ping_check
      end
    end

    private

    # --- HTTP -------------------------------------------------------------------------------------

    def http_check
      uri = URI.parse(@monitor.url)
      return blocked unless %w[http https].include?(uri.scheme)
      # Risolve UNA volta l'IP pubblico e lo pinna sulla connessione (anti DNS-rebinding: ri-risolvere
      # l'host al connect riaprirebbe il TOCTOU tra validazione e ping).
      address = DevelopmentLab.address(uri, organization: @monitor.project.organization) || NetworkGuard.resolved_public_address(uri.host)
      return blocked if address.nil?

      started = clock
      response, ssl_expires_at = perform_http(uri, address)
      elapsed = ((clock - started) * 1000).round
      up = response.code.to_i == @monitor.expected_status
      error = up ? nil : "unexpected_status_#{response.code}"
      # Keyword attesa nel body (solo metodi con body): assente → il check fallisce anche con status ok.
      if up && keyword_expected? && !response.body.to_s.include?(@monitor.expected_body_keyword)
        up = false
        error = "keyword_missing"
      end
      Result.new(up:, status_code: response.code.to_i, response_time_ms: elapsed, error:, ssl_expires_at:)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      down("timeout")
    rescue StandardError => e
      down(e.class.name.demodulize.underscore)
    end

    def keyword_expected?
      @monitor.expected_body_keyword.present? && @monitor.http_method.to_s.upcase != "HEAD"
    end

    # Ritorna [response, ssl_expires_at]: il not_after del certificato viene letto dentro la sessione
    # (peer_cert è disponibile solo a connessione aperta; WebMock nei test lo lascia nil).
    def perform_http(uri, address)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = address   # IP validato pinnato; Host header/SNI/verifica cert restano su uri.host
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @monitor.timeout_seconds
      http.read_timeout = @monitor.timeout_seconds
      request_class = METHODS.fetch(@monitor.http_method.to_s.upcase, Net::HTTP::Get)
      response = BoundedHttp.request(http, request_class.new(uri.request_uri),
                                     max_bytes: 2.megabytes, timeout: @monitor.timeout_seconds)
      [ response, http.use_ssl? ? http.peer_cert&.not_after : nil ]
    end

    # --- TCP (porta) ------------------------------------------------------------------------------

    def tcp_check
      address = NetworkGuard.resolved_public_address(@monitor.host)
      return blocked if address.nil?

      started = clock
      Socket.tcp(address, @monitor.port, connect_timeout: @monitor.timeout_seconds, &:close)
      elapsed = ((clock - started) * 1000).round
      Result.new(up: true, status_code: nil, response_time_ms: elapsed, error: nil)
    rescue Errno::ETIMEDOUT, IO::TimeoutError
      down("timeout")
    rescue SystemCallError, SocketError => e
      down(e.class.name.demodulize.underscore)
    end

    # --- DNS --------------------------------------------------------------------------------------

    # Risolve l'host: up se ritorna almeno un indirizzo. Non apre connessioni → nessun blocco SSRF (la
    # sola risoluzione non raggiunge la rete interna). resolve ha già timeout e non solleva (→ []).
    def dns_check
      started = clock
      addresses = NetworkGuard.resolve(@monitor.host)
      elapsed = ((clock - started) * 1000).round
      if addresses.any?
        Result.new(up: true, status_code: nil, response_time_ms: elapsed, error: nil)
      else
        down("dns_no_record")
      end
    end

    # --- PING (ICMP) ------------------------------------------------------------------------------

    def ping_check
      address = NetworkGuard.resolved_public_address(@monitor.host)
      return blocked if address.nil?

      started = clock
      reachable = icmp_reachable?(address, @monitor.timeout_seconds)
      elapsed = ((clock - started) * 1000).round
      reachable ? Result.new(up: true, status_code: nil, response_time_ms: elapsed, error: nil) : down("unreachable")
    rescue Errno::EACCES, Errno::EPERM
      # ICMP unprivileged non consentito in questo ambiente (net.ipv4.ping_group_range non include il
      # gruppo del processo). Degrado esplicito: l'utente vede subito che il ping non è disponibile qui.
      down("icmp_unavailable")
    rescue *IPV6_UNAVAILABLE_ERRORS => e
      address && ipv6?(address) ? down("ipv6_unavailable") : down(e.class.name.demodulize.underscore)
    rescue SystemCallError, SocketError, IOError => e
      # Ogni altro errore di rete diventa un esito down registrabile, come per tcp: il job non fallisce più
      # senza scrivere il check e il monitor non resta «unknown» (CYRA-1239).
      down(e.class.name.demodulize.underscore)
    end

    def ipv6?(address) = IPAddr.new(address).ipv6?

    # ICMP echo via socket DATAGRAM (SOCK_DGRAM/IPPROTO_ICMP o IPPROTO_ICMPV6): non richiede root né
    # CAP_NET_RAW, solo che l'host abbia net.ipv4.ping_group_range configurato (vale per entrambe le
    # famiglie). La famiglia segue l'IP già validato e pinnato da NetworkGuard (CYRA-1239). Il kernel
    # riscrive l'identifier con la porta del socket; leggiamo il primo messaggio e verifichiamo il reply.
    # simplecov:disable I/O di rete a basso livello — non eseguibile in CI (stubbato in ping_spec).
    def icmp_reachable?(address, timeout)
      ipv6 = ipv6?(address)
      socket = icmp_socket(ipv6)
      socket.connect(Socket.sockaddr_in(0, address))
      socket.send(icmp_echo_packet(ipv6:), 0)
      return false unless socket.wait_readable(timeout)

      data, = socket.recvfrom(1500)
      icmp_echo_reply?(data, ipv6:)
    ensure
      socket&.close
    end

    def icmp_socket(ipv6)
      if ipv6
        Socket.new(Socket::AF_INET6, Socket::SOCK_DGRAM, Socket::IPPROTO_ICMPV6)
      else
        Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, Socket::IPPROTO_ICMP)
      end
    end

    def icmp_echo_packet(ipv6: false)
      payload = "closeyourit".b
      # ICMPv6: checksum=0, lo calcola il kernel sul pseudo-header IPv6.
      return [ ICMPV6_ECHO_REQUEST, 0, 0, 0, 1 ].pack("C2n3") + payload if ipv6

      # type, code, checksum=0 (placeholder), identifier=0 (kernel lo riscrive), sequence=1
      header = [ ICMP_ECHO_REQUEST, 0, 0, 0, 1 ].pack("C2n3")
      checksum = icmp_checksum(header + payload)
      [ ICMP_ECHO_REQUEST, 0, checksum, 0, 1 ].pack("C2n3") + payload
    end

    # Complemento a uno della somma a 16 bit (RFC 1071).
    def icmp_checksum(data)
      sum = data.unpack("n*").sum
      sum += data.getbyte(-1) << 8 if data.bytesize.odd?
      sum = (sum >> 16) + (sum & 0xffff) while sum > 0xffff
      (~sum) & 0xffff
    end
    # simplecov:enable

    # È un echo reply (type 0)? Portabilità: su Linux il socket ICMP datagram consegna il solo messaggio
    # ICMP, ma su Darwin (e sui raw socket) il messaggio è preceduto dall'header IPv4 → va saltato
    # (IHL * 4 byte, riconosciuto dal nibble di versione == 4) prima di leggere il byte del type.
    # ICMPv6 non porta mai l'header IP (RFC 3542 §3), e il reply ha type 129.
    def icmp_echo_reply?(data, ipv6: false)
      return false if data.blank?
      return data.getbyte(0) == ICMPV6_ECHO_REPLY if ipv6

      first = data.getbyte(0)
      offset = (first >> 4) == 4 ? (first & 0x0F) * 4 : 0
      data.bytesize > offset && data.getbyte(offset) == ICMP_ECHO_REPLY
    end

    # --- comuni -----------------------------------------------------------------------------------

    def blocked = down("blocked_address")

    def down(error) = Result.new(up: false, status_code: nil, response_time_ms: nil, error:)

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
