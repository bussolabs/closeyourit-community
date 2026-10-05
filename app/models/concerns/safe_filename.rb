# frozen_string_literal: true

# Nome con cui un binario viene consegnato al client (header Content-Disposition e URL firmata).
# Condiviso da chi ha `has_one_attached :file` più un `title` di scorta: allegati KB e documenti di
# progetto, che dal canale CLI vengono serviti con send_data e quindi si portano dietro il nome.
#
# Il grosso lo fa già ActiveStorage: `ActiveStorage::Filename#to_s` È `#sanitized`, che sostituisce
# con "-" i separatori di percorso, i tab/CR/LF e l'override RTL ‮. Qui NON lo rifacciamo —
# partiamo da lì e chiudiamo solo il residuo che quel `tr` non copre:
#   - gli altri caratteri di controllo (\x00-\x08, \x0B, \x0C, \x0E-\x1F, \x7F), che spezzano gli header;
#   - gli altri marcatori bidirezionali (‪-‭, ⁦-⁩), che come l'RTLO invertono
#     la resa del nome e fanno leggere "exehs.png" a chi sta salvando uno script.
# L'estensione resta intatta di proposito: `deploy.sh` deve restare `deploy.sh`, altrimenti chi
# scarica non sa più che cosa ha in mano.
module SafeFilename
  extend ActiveSupport::Concern

  def sanitized_filename
    base = file.attached? ? file.blob.filename.sanitized : title.to_s
    cleaned = base
              .gsub(/[[:cntrl:]]/, "")
              .gsub(/[‪-‮⁦-⁩]/, "")
              .strip
    cleaned.presence || safe_filename_fallback
  end

  private

  # Ultima spiaggia: file e titolo sono entrambi validati, quindi un record senza nessuno dei due non
  # esiste — ma un Content-Disposition vuoto sì, e il client si ritroverebbe a salvare "download".
  def safe_filename_fallback = "file"
end
