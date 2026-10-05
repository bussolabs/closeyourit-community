# frozen_string_literal: true

# MT-9 (CYAU-85) — Rimozione dei typed agent: il modello host-first non li usa più.
#
# L'esecuzione è già host-scoped (claim, eligibility, profilo della fase) e da CYAU-100 anche il manifest dei
# repository e il gate della pipeline closer derivano dall'host. Restava solo il catalogo: righe che nessuno
# legge, più i service account che le rappresentavano.
#
# SQL grezzo per scelta: questa migration sopravvive alla rimozione dei modelli `Agents::Agent`/`Command`/
# `Instruction` che avviene nello stesso cambiamento. Referenziarli la renderebbe non rieseguibile su una
# checkout futura.
#
# Ordine obbligato dalle FK: agenti → comandi → service account. `agents_agents.service_account_id` è
# ON DELETE RESTRICT, quindi finché esiste un agente il suo service account non è cancellabile.
# Le cascate fanno il resto: `agents_runs` e `connections_agent_targets` cadono con l'agente,
# `agents_instructions` e `connections_agent_command_projects` col comando.
#
# L'AUDIT STORICO RESTA LEGGIBILE: attempt, workflow, deferral e prenotazioni hanno FK ON DELETE SET NULL sui
# riferimenti all'agente — perdono il puntatore, non la riga. `agents_hosts.service_account_id` non viene mai
# toccato: l'identità delle macchine è un'altra cosa.
#
# Idempotente: rieseguirla non trova nulla da cancellare.
class RemoveTypedAgents < ActiveRecord::Migration[8.1]
  def up
    service_account_ids = select_values(<<~SQL.squish)
      SELECT DISTINCT service_account_id FROM agents_agents WHERE service_account_id IS NOT NULL
    SQL

    execute("DELETE FROM agents_agents")
    execute("DELETE FROM agents_commands")

    return if service_account_ids.empty?

    # Cancella i service account degli agenti, uno per savepoint. NON si enumerano a mano le FK che possono
    # bloccare: verso `accounts` ce ne sono 25 senza cascade — attempt storici, ticket segnalati, audit di
    # impersonation, provisioning dei secret — e una lista scritta a mano invecchierebbe al primo schema nuovo.
    # Si prova a cancellare e si lascia decidere al database: chi è ancora referenziato sopravvive intatto
    # (il savepoint annulla anche la membership), chi non lo è sparisce. Meglio un account orfano che una
    # migration che esplode a metà.
    #
    # La membership è un legame d'accesso, non audit: cade con l'account che rappresenta, come fa
    # `Accounts::Service::Retire`. L'identità delle macchine (`agents_hosts.service_account_id`) non è tra
    # questi id e non viene mai toccata.
    service_account_ids.each do |id|
      quoted = connection.quote(id)
      begin
        connection.transaction(requires_new: true) do
          execute("DELETE FROM connections_memberships WHERE account_id = #{quoted}")
          execute("DELETE FROM accounts WHERE id = #{quoted} AND kind = 1")
        end
      rescue ActiveRecord::InvalidForeignKey
        say("service account #{id} ancora referenziato: lasciato intatto", true)
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "I typed agent non si ricreano: il modello host-first non li prevede."
  end
end
