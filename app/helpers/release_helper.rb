# frozen_string_literal: true

# Come si scrive un rilascio in interfaccia (CYRA-394). Il campo arriva dagli SDK e può essere
# qualsiasi cosa: una versione leggibile (`v0.77.4`), lo SHA completo di un commit (quaranta
# caratteri), o niente. Nella colonna stretta del dettaglio due SHA affiancati si accavallavano
# fino a non leggersi — ed è il dato che chiude un'indagine in trenta secondi.
module ReleaseHelper
  # Uno SHA git: 40 caratteri esadecimali (o 7+, che è la forma già abbreviata). Solo questo si
  # accorcia: una versione semantica è già corta e va lasciata intatta.
  SHA = /\A[0-9a-f]{7,40}\z/i

  def release_sha?(release) = SHA.match?(release.to_s.strip)

  # La forma da leggere: SHA → sette caratteri, tutto il resto invariato.
  def release_label(release)
    value = release.to_s.strip
    release_sha?(value) ? value[0, 7] : value
  end

  # Il commit su GitHub, quando il progetto ha un repository agganciato E il rilascio è uno SHA.
  # Senza repo (o con una versione semantica) non c'è una pagina dove andare: nil, e la vista
  # mostra solo la copia — meglio nessun link che un link che non porta da nessuna parte.
  def release_commit_url(project, release)
    return nil unless release_sha?(release)

    repository = project&.github_repository
    return nil if repository.nil?

    "#{repository.html_url}/commit/#{release.to_s.strip}"
  end
end
