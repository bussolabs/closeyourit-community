# frozen_string_literal: true

# Pannello «Chi può vedere questi segreti» (CYRA-422): risolve le membership reali in nomi e ruoli, così
# chi salva un segreto sa chi altro potrà leggerlo. I `readers` arrivano già risolti da Secrets::Readers
# (nessuna query qui). `reveal_names` filtra la rassicurazione sui permessi di CHI GUARDA: senza titolo a
# vedere i membri, mostra solo il conteggio (mai un elenco di nomi → niente fuga di informazioni
# sull'organizzazione). `permissions_href`, se presente, rimanda alla pagina di accessi e permessi.
class SecretReadersComponent < Ui::BaseComponent
  ROLE_COLORS = { owner: :amber, admin: :indigo, member: :gray, customer: :sky }.freeze

  def initialize(readers:, reveal_names:, permissions_href: nil, test_id: "secret-readers")
    @readers = Array(readers)
    @reveal_names = reveal_names
    @permissions_href = permissions_href
    @test_id = test_id
  end

  private

  attr_reader :readers, :reveal_names, :permissions_href, :test_id

  def role_color(role)
    ROLE_COLORS.fetch(role.to_sym, :gray)
  end
end
