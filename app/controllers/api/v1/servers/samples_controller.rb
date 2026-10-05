# frozen_string_literal: true

module Api
  module V1
    module Servers
      # Ingest degli agent di server monitoring (closeyourit-agent, push ogni 60s). Bearer =
      # enrollment token org-scoped: risolve/crea l'host per fingerprint (sincrono, così un host
      # revocato riceve 403 e l'agent si ferma), poi accoda l'ingest pesante. 202 {data:{accepted}}.
      # Il body può arrivare gzip (Content-Encoding dell'agent): Rails NON lo decomprime → parse
      # manuale del raw body (sniff magic bytes, come Api::IngestController), MAI params.
      class SamplesController < Api::BaseController
        include AgentAuthentication

        before_action :authenticate_agent!

        GZIP_MAGIC = "\x1f\x8b".b
        HOST_TOKEN_MIN_VERSION = Gem::Version.new("0.4.0")

        def create
          if request.content_length.to_i > ::Servers::Constants::MAX_PAYLOAD_BYTES
            return render_error("R413-SERVER-002", "Payload troppo grande", status: :content_too_large)
          end

          payload = parse_payload
          if payload == :too_large
            return render_error("R413-SERVER-002", "Payload troppo grande", status: :content_too_large)
          end
          if payload.nil?
            return render_error("R422-SERVER-004", "Payload malformato", status: :unprocessable_content)
          end

          fingerprint = payload["fingerprint"].to_s.strip
          if fingerprint.blank?
            return render_error("R422-SERVER-001", "Fingerprint mancante", status: :unprocessable_content)
          end

          if Current.server_host && !ActiveSupport::SecurityUtils.secure_compare(Current.server_host.fingerprint, fingerprint)
            return render_error("R403-SERVER-003", "Fingerprint non corrispondente", status: :forbidden)
          end
          host = Current.server_host || ::Servers::RegisterHost.call(
            organization: Current.organization, fingerprint:, hostname: payload.dig("host", "hostname"),
            enrollment_token: current_enrollment_token
          ).value
          if host.revoked?
            return render_error("R403-SERVER-002", "Host revocato", status: :forbidden)
          end

          # CYRA-649 — l'ora di arrivo si registra QUI, sincrona, prima di accodare qualsiasi cosa: è
          # l'unica misura di salute che non dipende da quanto è in ritardo la corsia dei dati né
          # dall'orologio della macchina. `update_columns` come in record_enrollment_conflict: hot
          # path, niente callback né validazioni. Un UPDATE per macchina al minuto.
          host.update_columns(last_push_at: Time.current, updated_at: Time.current)

          ::Servers::IngestJob.perform_later(host_id: host.id, payload: payload)
          data = { accepted: true, host_id: host.id }
          if Current.server_host.nil? && supports_host_token?(payload["agent_version"])
            secret = issue_host_token(host)
            data[:host_token] = secret if secret
          end
          render json: { data: }, status: :accepted
        end

        private

        def supports_host_token?(version)
          Gem::Version.new(version.to_s) >= HOST_TOKEN_MIN_VERSION
        rescue ArgumentError
          false
        end

        # CYRA-245 — la credenziale per-host si emette SOLO a una macchina che non ne ha già una viva.
        # Prima ogni arruolamento revocava quella esistente ed emetteva la propria: il codice della
        # flotta è lo stesso su ogni macchina e sta in chiaro su ognuna, l'impronta si legge dal
        # pannello, quindi chi aveva entrambi si presentava al posto di una macchina qualsiasi e la
        # sonda vera restava esclusa per sempre (l'agent non ricade sul codice della flotta). Lo stesso
        # succedeva per sbaglio a ogni reinstallazione della sonda.
        #
        # Sostituire una credenziale viva è ora un gesto esplicito di una persona, dalla scheda della
        # macchina: apre una finestra di riadozione, e solo dentro quella finestra il primo
        # arruolamento prende il posto del precedente. Fuori dalla finestra il tentativo resta scritto
        # sulla macchina (e nel log) ma il push viene comunque accettato: rifiutarlo trasformerebbe
        # ogni reinstallazione in un buco nei dati, e non è l'ingest che il ticket protegge.
        #
        # Lock di riga sull'host: due arruolamenti concorrenti sulla stessa macchina emetterebbero
        # altrimenti due credenziali entrambe attive, e da lì nessuna delle due sarebbe più
        # sostituibile senza una riadozione.
        def issue_host_token(host)
          host.with_lock do
            active = host.host_tokens.active
            if active.none?
              issue_secret(host)
            elsif host.reenrollment_open?
              # La finestra si chiude appena è servita: la riadozione vale per UNA sonda, non per
              # tutte quelle che passano nell'ora successiva.
              active.update_all(revoked_at: Time.current)
              host.update!(reenrollment_requested_at: nil)
              issue_secret(host)
            else
              record_enrollment_conflict(host)
              nil
            end
          end
        end

        def issue_secret(host)
          issued = ::Servers::HostTokens::Issue.call(host:)
          issued.ok? ? issued.value[:secret] : nil
        end

        # Il tentativo va registrato dove lo vede una persona: la scheda della macchina lo dice e
        # propone la riadozione. Sovrascrive l'istante precedente — serve l'ultimo, non un archivio:
        # una sonda che ha perso la propria credenziale ripusserebbe ogni 60s e riempirebbe qualunque
        # elenco. `update_columns` per non svegliare callback e validazioni su un hot path.
        def record_enrollment_conflict(host)
          now = Time.current
          host.update_columns(enrollment_conflict_at: now, updated_at: now)
          Rails.logger.warn(
            "Servers enrollment conflict host_id=#{host.id} organization_id=#{host.organization_id} " \
            "fingerprint=#{host.fingerprint}"
          )
          nil
        end

        # Hash | :too_large (bomb decompressa oltre il limite) | nil (non parsabile / non-oggetto).
        # Lettura LIMITATA a MAX+1: una gzip-bomb (1 MB compresso → GB decompressi) alloca al più
        # MAX+1 byte invece dell'intero stream — il check too_large scatta senza esaurire la RAM.
        def parse_payload
          bytes = request.body.read.to_s.b
          data =
            if bytes.byteslice(0, 2) == GZIP_MAGIC
              Zlib::GzipReader.new(StringIO.new(bytes))
                              .read(::Servers::Constants::MAX_PAYLOAD_BYTES + 1).to_s
            else
              bytes
            end
          return :too_large if data.bytesize > ::Servers::Constants::MAX_PAYLOAD_BYTES

          parsed = JSON.parse(data)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError, Zlib::Error
          nil
        end
      end
    end
  end
end
