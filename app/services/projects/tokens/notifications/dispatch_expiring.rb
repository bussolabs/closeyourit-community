# frozen_string_literal: true

module Projects
  module Tokens
    module Notifications
      # Promemoria di scadenza di una credenziale di ingest (CYRA-716): dato un token in preavviso o
      # già scaduto, avvisa chi può rimediare — owner + chi ha tokens.manage sul progetto
      # (Alerting::Recipients.for_tokens). Gemello strutturale di
      # Secrets::Notifications::DispatchRotationDue: rule_id nil, subject = il token, gating delle
      # preferenze via Preference#channels_for, in-app SEMPRE consegnata.
      #
      # Idempotente: il dedup_key è ancorato a (token, scadenza) e NON alla data odierna, così un
      # token scaduto e lasciato lì non rimanda un avviso ogni notte; spostare la scadenza in avanti
      # riarma l'avviso da sé, senza reset espliciti.
      class DispatchExpiring < ApplicationService
        def initialize(token:, at: Time.current)
          @token = token
          @at = at
        end

        def call
          return Result.ok(0) unless notifiable?

          content = Content.for(token: @token, at: @at)
          delivered = 0
          Alerting::Recipients.for_tokens(project: @token.project).each do |account|
            delivered += deliver_to(account, content)
          end
          Result.ok(delivered)
        end

        private

        # Guardia difensiva: SOLO due_soon/expired, e mai un token revocato (che non interessa più a
        # nessuno). Il job filtra già con lo scope due_for_expiry, ma il dispatch resta sicuro anche
        # invocato direttamente da console o test su un token fuori finestra.
        def notifiable?
          return false if @token.revoked?

          %i[due_soon expired].include?(@token.expiry_status(at: @at))
        end

        def organization = @token.project.organization

        def deliver_to(account, content)
          pref = Alerting::Preference.for(account: account, organization: organization)
          channels = pref.channels_for(:project_token_expiring, connected_telegram: account.connected_telegram?)

          count = 0
          count += deliver_in_app(account, content) # in-app SEMPRE
          telegram = deliver_telegram(account, content, channels[:telegram])
          unless ::Notifications::Deliver.reached_by_telegram?(telegram)
            count += deliver_email(account, content, pref, channels[:email])
          end
          count + (telegram&.ok? ? 1 : 0)
        end

        def deliver_in_app(account, content)
          result = Deliver.in_app(account: account, token: @token, content: content,
                                  dedup_key: dedup_key(account, "in_app"))
          result.ok? ? 1 : 0
        end

        def deliver_email(account, content, pref, decision)
          return 0 unless decision[:deliver]

          result = Deliver.email(account: account, token: @token, content: content,
                                 dedup_key: dedup_key(account, "email"),
                                 quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket])
          result.ok? ? 1 : 0
        end

        # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
        def deliver_telegram(account, content, decision)
          return unless decision[:deliver]

          Deliver.telegram(account: account, token: @token, content: content,
                           dedup_key: dedup_key(account, "telegram"), bucket: decision[:bucket])
        end

        # Una notifica per (token, scadenza, account, canale). expires_at cambia solo se qualcuno
        # sposta la data: stessa scadenza → stessa chiave → niente avviso ripetuto ogni giorno
        # (idempotenza voluta, non un difetto).
        def dedup_key(account, via)
          "project_token_expiry:#{@token.id}:#{@token.expires_at.to_i}:#{account.id}:#{via}"
        end
      end
    end
  end
end
