# frozen_string_literal: true

require "rails_helper"

# CYRA-727 — una pagina dell'area utenti può nascere senza chiedere niente a nessuno, e nessuno se ne
# accorge: i dati che mostra sono già tagliati sul perimetro dell'account, quindi la pagina sembra
# corretta. Il buco si vede solo dove si SCRIVE — un'azione che modifica dati e non passa da una
# chiave-permesso non ha nessuna rete sotto, e la si scopre leggendo il file, non usando il prodotto.
#
# Qui si controlla il sorgente, non il comportamento: ogni controller dell'area member deve o
# interrogare un permesso, o dichiarare per iscritto perché non serve (`permission_not_required`).
# È una rete, non una prova — le prove vere sono i request spec di ogni area, e la rete a runtime è
# `Member::PermissionDeclaration#verify_permission_declared`, che guarda la singola AZIONE.
RSpec.describe "Ogni pagina dell'area utenti dichiara il proprio permesso", type: :model do
  # I modi in cui un controller può interrogare i permessi: la guardia che nega, quella owner/god, il
  # predicato usato inline, le sue scorciatoie org-level e il gate di contenuto del cliente esterno.
  MODI_DI_CHIEDERE_IL_PERMESSO = [
    "require_permission!", "require_actor_privileged!", "can?", "can_any?",
    "can_view_", "can_manage_permissions?", "customer_content_gate"
  ].freeze

  before { Rails.application.eager_load! }

  # Per DISCENDENZA e non per prefisso delle rotte: `ErrorsController` (le pagine 404/500) eredita da
  # Member::BaseController pur vivendo fuori dall'area, e cercarlo sotto `member/` lo lascerebbe fuori
  # — cioè proprio il caso che questa prova esiste per prendere.
  def controller_dell_area_member
    Member::BaseController.descendants.select(&:name).sort_by(&:name)
  end

  # I file che compongono davvero il controller: il suo, le basi intermedie e i concern che include.
  # Ci si ferma a Member::BaseController — quello che sta lì vale per tutti e non dice niente su
  # questa pagina. Il gate di `Member::Knowledge::PagesController`, per esempio, vive nel concern
  # KnowledgePageManagement: cercarlo nel solo file del controller lo direbbe scoperto.
  def sorgenti_di(klass)
    klass.ancestors.take_while { |modulo| modulo != Member::BaseController }
         .filter_map { |modulo| percorso_di(modulo) }
         .select { |percorso| percorso.start_with?(Rails.root.join("app").to_s) }.uniq
  end

  def percorso_di(modulo)
    return nil if modulo.name.blank?

    Object.const_source_location(modulo.name)&.first
  rescue NameError
    nil
  end

  # I commenti restano fuori: una spiegazione che NOMINA `require_permission!` non è un gate, e
  # contarla farebbe passare per protetta una pagina che non chiede niente.
  def codice_senza_commenti(percorso)
    File.readlines(percorso).grep_v(/\A\s*#/).join
  end

  def chiede_un_permesso?(klass)
    sorgenti_di(klass).any? do |percorso|
      codice = codice_senza_commenti(percorso)
      MODI_DI_CHIEDERE_IL_PERMESSO.any? { |modo| codice.include?(modo) }
    end
  end

  it "ogni controller interroga un permesso o scrive perché non serve" do
    scoperti = controller_dell_area_member.reject do |klass|
      chiede_un_permesso?(klass) || klass.permission_exemptions.any?
    end

    expect(scoperti).to be_empty, <<~MESSAGGIO
      Queste pagine dell'area utenti non chiedono nessun permesso e non dicono perché:

      #{scoperti.map { |klass| "  #{klass.name}" }.join("\n")}

      Aggiungi il gate che serve (`require_permission!`), oppure dichiara il motivo nel controller:

        permission_not_required "Casella personale: ognuno vede e gestisce solo le proprie."
    MESSAGGIO
  end

  it "ogni motivo scritto è una frase, non un segnaposto" do
    troppo_corti = controller_dell_area_member.flat_map do |klass|
      klass.permission_exemptions.filter_map do |azione, motivo|
        "#{klass.name}##{azione}: #{motivo.inspect}" if motivo.to_s.strip.length < 20
      end
    end

    expect(troppo_corti).to be_empty, <<~MESSAGGIO
      Un motivo che non si legge non è un motivo. Questi vanno scritti per esteso:

      #{troppo_corti.join("\n")}
    MESSAGGIO
  end
end
