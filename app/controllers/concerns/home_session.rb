# frozen_string_literal: true

# Le decisioni messe da parte «per adesso» (CYRA-657).
#
# Stanno in `session` e NON nel database, al contrario del rimando a domani: sono due gesti diversi.
# «Salta» vuol dire «fammi vedere il resto, poi ci torno» e deve morire quando si chiude tutto;
# «rimanda a domani» vuol dire «non oggi» e deve valere anche da un altro computer. Scriverli nello
# stesso posto vorrebbe dire togliere all'uno o all'altro il suo significato.
#
# Il tetto esiste perché la sessione viaggia nel cookie: senza, chi preme «salta» cinquanta volte si
# porta dietro cinquanta chiavi in ogni richiesta.
module HomeSession
  extend ActiveSupport::Concern

  SKIPPED_KEY = :home_skipped
  PREVIOUS_KEY = :home_previous
  # Oltre questo numero non è più «guardo il resto»: è una coda che non si vuole smaltire, e per
  # quella c'è il rimando a domani, che dura e non sta in un cookie.
  SKIPPED_CAP = 50

  private

  def skipped_cards = Array(session[SKIPPED_KEY])

  def skip_card(key)
    return if key.blank?

    session[SKIPPED_KEY] = (skipped_cards - [ key ] + [ key ]).last(SKIPPED_CAP)
    session[PREVIOUS_KEY] = key
  end

  # Torna indietro: l'ultima messa da parte rientra in coda. Se non c'è più niente da riprendere si
  # ripiega sull'ultima vista, che almeno si può rileggere — «indietro» non deve mai non fare niente
  # in silenzio.
  def unskip_last_card
    skipped = skipped_cards
    resumed = skipped.pop
    session[SKIPPED_KEY] = skipped
    resumed || session[PREVIOUS_KEY]
  end

  def clear_skipped_cards
    session.delete(SKIPPED_KEY)
    session.delete(PREVIOUS_KEY)
  end

  def remember_last_card(key)
    session[PREVIOUS_KEY] = key if key.present?
  end
end
