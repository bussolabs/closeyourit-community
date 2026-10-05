# frozen_string_literal: true

require "rails_helper"

# CYRA-746 — il modello del ticket nominava per esteso le classi del dominio agenti (la presa in
# carico, la lavorazione, le lapidi, i rinvii di coda): chi toccava gli agenti doveva aprire il
# ticket, e il ticket cresceva ogni volta che gli agenti imparavano una cosa nuova. La direzione
# giusta è l'opposta — sono gli agenti a conoscere il ticket — e si ottiene spostando le relazioni
# in un concern che vive dentro `app/models/agents/`: il ticket lo include e basta, il dominio
# agenti resta padrone di cosa quelle relazioni sono.
#
# L'altra metà è l'account, che portava sessantasette relazioni verso cinquantuno aree diverse. La
# maggior parte non serviva a leggere nulla: erano `has_many` di solo metadato («creato da»,
# «invitato da», «attore dell'evento») dichiarate soltanto per far cadere a NULL la colonna quando
# l'account sparisce — cosa che la chiave esterna a DB fa già da sé (`on_delete: :nullify`). Via
# quelle, il comportamento non cambia: lo dimostrano le prove di cancellazione in
# `spec/requests/valhalla/accounts_spec.rb`.
#
# Qui si guarda il SORGENTE, non il comportamento. Il comportamento lo tengono le prove dei domini.
RSpec.describe "Le dipendenze fra modelli puntano nel verso giusto", type: :model do
  let(:sorgente_ticket) { Rails.root.join("app/models/ticketing/ticket.rb").read }
  let(:sorgente_account) { Rails.root.join("app/models/accounts/account.rb").read }
  let(:sorgente_concern) { Rails.root.join("app/models/agents/ticket_automatable.rb") }

  describe "il modello del ticket" do
    # Si guarda il codice, non le note: un commento che dice chi ti chiama è documentazione, non una
    # dipendenza — al contrario di una riga che nomina la classe per costruirci sopra una relazione.
    it "non nomina nessuna classe del dominio agenti" do
      codice = sorgente_ticket.lines.grep_v(/^\s*#/).join
      nominate = codice.scan(/(?<![:\w])Agents::[A-Z]\w*(?:::[A-Z]\w*)*/).uniq
                       .reject { |nome| nome == "Agents::TicketAutomatable" }

      expect(nominate).to be_empty,
                          "Il ticket nomina ancora #{nominate.join(', ')}: quelle relazioni vanno " \
                          "dichiarate in Agents::TicketAutomatable, non qui."
    end

    it "include il concern del dominio agenti" do
      expect(sorgente_ticket.match?(/^\s*include Agents::TicketAutomatable$/)).to be(true),
                                                                                 "Il ticket non include " \
                                                                                 "Agents::TicketAutomatable."
    end

    # Le relazioni sono le stesse di prima: spostare la dichiarazione non deve cambiare né la classe
    # collegata, né la colonna, né cosa succede alla cancellazione del ticket. `dependent` è la parte
    # che un refactor distratto perde per strada: `agent_workflow` cade col ticket, la presa in carico
    # e le lapidi le porta via la chiave esterna (nessun callback, così l'ordine di lock resta
    # ticket→lease per i service concorrenti).
    {
      agent_lease: { macro: :has_one, class_name: "Agents::Lease", dependent: nil },
      agent_workflow: { macro: :has_one, class_name: "Agents::Workflow", dependent: :destroy },
      agent_lease_tombstones: { macro: :has_many, class_name: "Agents::Leases::Tombstone", dependent: nil },
      agent_ticket_queue_deferrals: { macro: :has_many, class_name: "Agents::TicketQueueDeferral", dependent: nil }
    }.each do |nome, atteso|
      it "conserva #{nome} con le stesse opzioni" do
        relazione = Ticketing::Ticket.reflect_on_association(nome)

        expect(relazione).to be_present, "Il ticket ha perso la relazione #{nome}."
        expect(relazione.macro).to eq(atteso[:macro])
        expect(relazione.options[:class_name]).to eq(atteso[:class_name])
        expect(relazione.options[:foreign_key]).to eq(:ticket_id)
        expect(relazione.options[:dependent]).to eq(atteso[:dependent])
        expect(relazione.options[:inverse_of]).to eq(:ticket)
      end
    end
  end

  describe "il concern del dominio agenti" do
    it "vive dentro app/models/agents e dichiara lui le relazioni" do
      expect(sorgente_concern.exist?).to be(true),
                                         "Manca app/models/agents/ticket_automatable.rb: senza, la " \
                                         "dipendenza resta puntata da Ticketing verso Agents."

      testo = sorgente_concern.read
      %w[agent_lease agent_workflow agent_lease_tombstones agent_ticket_queue_deferrals].each do |nome|
        expect(testo).to include(nome), "Il concern non dichiara #{nome}."
      end
    end

    it "è un concern del namespace Agents" do
      expect(Agents::TicketAutomatable).to be_a(Module)
      expect(Ticketing::Ticket.ancestors).to include(Agents::TicketAutomatable)
    end
  end

  describe "l'account" do
    # Le relazioni tolte: nessuna di queste leggeva niente da nessuna parte — l'unico compito era
    # il `dependent: :nullify`, che ripete in Ruby ciò che la chiave esterna fa già a DB. Se una
    # torna, torna con un lettore: `Modello.where(created_by: account)` non ha bisogno di una
    # relazione dichiarata per funzionare.
    let(:relazioni_di_solo_metadato) do
      %w[
        created_organizations created_projects created_groups created_teams
        default_assigned_projects default_assigned_teams default_assigned_organizations
        created_workload_actions created_roles
        actor_authorization_events true_actor_authorization_events
        created_platforms created_ticket_priorities created_ticket_statuses
        created_milestones created_project_documents
        created_secret_variables secret_events created_secret_versions
        created_log_links created_server_links created_chat_conversations
        sent_invitations impersonated_sessions
      ]
    end

    it "non porta più le relazioni di solo metadato" do
      rimaste = relazioni_di_solo_metadato.select { |nome| Accounts::Account.reflect_on_association(nome) }

      expect(rimaste).to be_empty,
                         "L'account dichiara ancora #{rimaste.join(', ')}: sono relazioni che nessuno " \
                         "legge, tenute in piedi da un dependent che la chiave esterna fa già da sé."
    end

    # Il tetto della Definition of Done, misurato sulle relazioni dichiarate nel file. Sopra questa
    # misura l'account sta tornando a essere il posto dove ogni dominio nuovo appende la sua riga.
    it "sta sotto le cinquanta relazioni dichiarate" do
      misura = sorgente_account.scan(/^\s{4}has_many /).size

      expect(misura).to be <= 50,
                        "L'account dichiara #{misura} relazioni: quelle di solo metadato non servono, " \
                        "la chiave esterna nullifica lo stesso."
    end

    # Restano, e restano per un motivo. Le due verso gli eventi di impersonation sono l'unico
    # `restrict_with_error` la cui chiave esterna NON ha `on_delete`: toglierle non farebbe cadere il
    # gate, lo trasformerebbe in un'eccezione di chiave esterna — cioè in un cambio di comportamento,
    # che è esattamente ciò che questo lavoro non deve fare. Quelle verso la cronologia (`actor_events`,
    # `true_actor_events`) hanno la stessa chiave esterna senza `on_delete`: lì il `dependent: :nullify`
    # è il solo motivo per cui un account cancellabile si cancella davvero.
    %w[impersonation_events_as_target impersonation_events_as_god actor_events true_actor_events].each do |nome|
      it "conserva #{nome}, che regge la cancellazione" do
        expect(Accounts::Account.reflect_on_association(nome)).to be_present
      end
    end
  end

  # La rete che rende innocua la rimozione: un `inverse_of:` lasciato indietro punta a una relazione
  # che non esiste più, e Rails se ne accorge solo quando qualcuno percorre quella direzione — cioè
  # dentro una richiesta, non qui. Si guardano le relazioni vere di tutti i modelli, non il testo dei
  # file: l'`inverse_of` scritto è il solo che conta, e il nome che nomina o esiste o no.
  it "nessun modello punta a una relazione dell'account che non esiste più" do
    Rails.application.eager_load!
    nomi = Accounts::Account.reflect_on_all_associations.map(&:name)

    orfani = ApplicationRecord.descendants.sort_by(&:name).flat_map { |modello|
      modello.reflect_on_all_associations.filter_map { |relazione|
        atteso = relazione.options[:inverse_of]
        next if atteso.blank? || relazione.options[:class_name] != "Accounts::Account"

        "#{modello.name}##{relazione.name} → #{atteso}" unless nomi.include?(atteso.to_sym)
      }
    }

    expect(orfani).to be_empty,
                      "Questi inverse_of puntano a una relazione che l'account non ha più: " \
                      "#{orfani.join(', ')}. Vanno messi a `inverse_of: false`."
  end
end
