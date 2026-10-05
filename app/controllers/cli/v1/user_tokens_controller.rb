# frozen_string_literal: true

module Cli
  module V1
    # I PROPRI token CLI (Accounts::ApiToken) gestiti dal terminale: elenco e revoca. Controller flat
    # (niente Cli::V1::Auth, che ombreggerebbe ::Auth) montato su /cli/v1/auth/tokens.
    #
    # Nessuna permission key: i token sono dati POSSEDUTI da chi chiama, come i todo e il vault
    # personale. Lo scoping è l'ownership (Current.account.api_tokens) e un token altrui esce dallo
    # scope → RecordNotFound → R404, mai 403: un 403 confermerebbe che quell'id esiste.
    #
    # La lista attraversa le organizzazioni di proposito: un token ne serve UNA sola, ma chi ha perso
    # il portatile deve chiuderli tutti da un posto solo — costringerlo a indovinare l'org di ognuno
    # è il modo di lasciarne aperto uno.
    class UserTokensController < Cli::V1::BaseController
      def index
        tokens = Current.account.api_tokens.includes(:organization)
                        .order(revoked_at: :asc, created_at: :desc)
        render_ok(AccountApiTokenSerializer.new(tokens, params: { current_token_id: Current.api_token.id }))
      end

      # Revoca soft (revoked_at): la riga resta, e la lista continua a dire quando quel dispositivo è
      # stato chiuso. Revocare il token IN USO è legittimo ed è anzi il caso principale (`logout` che
      # chiude davvero, non solo la copia locale): la richiesta è già autenticata quando la revoca
      # avviene, quindi la risposta esce regolarmente — è la richiesta SUCCESSIVA a prendere 401.
      def destroy
        ::Accounts::ApiTokens::Revoke.call(token: find_own_token)
        render_no_content
      end

      private

      # `current` come id: la CLI ha in mano il segreto, non l'UUID del token che lo rappresenta, e
      # farle chiedere prima whoami per chiudersi da sola sarebbe un giro in più che può fallire a
      # metà lasciando il token vivo.
      def find_own_token
        return Current.api_token if params[:id] == "current"

        Current.account.api_tokens.find(params[:id])
      end
    end
  end
end
