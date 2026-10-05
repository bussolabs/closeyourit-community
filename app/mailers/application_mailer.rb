class ApplicationMailer < ActionMailer::Base
  # Le view di TUTTI i mailer vivono sotto app/views/mails/<dominio>/<mailer>/.
  # ActionMailer risolve il template con `headers[:template_path] || mailer_name`:
  # impostando `template_path` come proc (valutato per-istanza) prefissiamo
  # `mailer_name` (es. "auth/passwords_mailer") con "mails/" — un solo punto,
  # ogni mailer namespaced eredita il path senza configurazione per-mailer.
  # Mittente di TUTTE le email del prodotto. Il dominio dev'essere abilitato a spedire presso il
  # fornitore (DKIM + MX verificati), altrimenti la spedizione viene rifiutata e nessuno riceve niente —
  # per un anno è stato `notifications.closeyour.it`, che non ha mai avuto un solo record di posta
  # (CYRA-233). Cambiarlo significa cambiarlo anche in config/deploy.yml e config/deploy.staging.yml:
  # spec/config/mail_sender_spec.rb fallisce se i tre divergono, Ops::MailSenderCheck se il fornitore
  # non riconosce il dominio.
  DEFAULT_FROM = "CloseYourIt <noreply@notifications.closeyour.it>"

  default from: ENV.fetch("MAIL_FROM", DEFAULT_FROM),
          template_path: -> { "mails/#{self.class.mailer_name}" }

  layout "mailer"

  before_deliver :exclude_service_accounts

  # Stile email condiviso (palette/accento/stili inline) disponibile in tutte le view mailer.
  helper MailerHelper

  # Localizza l'INTERA azione mailer (soggetto + corpo) nella lingua del destinatario. Le view girano
  # in un job (deliver_later) dove I18n.locale è il default → senza questo wrap ogni email uscirebbe in
  # inglese. Serve avvolgere `process` e NON `mail`: il `subject:` è un argomento `t(...)` valutato
  # PRIMA della chiamata a `mail`, quindi un wrap su `mail` localizzerebbe solo il corpo. Il
  # destinatario è derivato dal PRIMO argomento dell'azione (convenzione dei mailer): un Account, o un
  # oggetto che porta l'account (`notification.account`) o l'invitante (`invitation.invited_by`).
  # Sconosciuto/nil → default I18n. with_locale isola il cambio (nessun leak tra job sullo stesso thread).
  def process(action, *args)
    I18n.with_locale(recipient_locale(args.first)) { super }
  end

  # CYRA-672 — lega il messaggio alle righe di notifica che rappresenta, cosi'
  # Notifications::DeliveryObserver puo' segnarle consegnate quando la spedizione riesce davvero.
  # Accetta una notifica sola o un elenco: il riepilogo periodico ne porta molte.
  def track_delivery(notifications)
    ids = Array(notifications).compact.map(&:id)
    return if ids.empty?

    headers[::Notifications::DeliveryObserver::HEADER] = ids.join(",")
  end

  # Un a capo nel subject fa rifiutare l'INTERA spedizione dal fornitore, con
  # "The `\n` is not allowed in the `subject` field": non parte niente, nemmeno il corpo.
  # In produzione ha bloccato 3.718 invii fra il 9 e il 27 agosto senza svegliare nessuno
  # (CYRA-671). Il vettore più comune è un titolo scritto su più righe interpolato via
  # `t(...)`, ma la sorgente può essere qualunque campo libero (nome organizzazione,
  # titolo di un allarme): la difesa sta qui una volta sola, non in ogni mailer.
  # Gli spazi si comprimono invece di sparire, altrimenti "riga\nriga" diventa "rigariga".
  def mail(headers = {}, &block)
    headers[:subject] = headers[:subject].to_s.gsub(/\s+/, " ").strip if headers[:subject]
    super
  end

  private

  # CYRA-836: controlla gli indirizzi effettivi anche per job già accodati, digest e inviti.
  # Filtra ogni intestazione separatamente per preservare gli eventuali destinatari umani.
  def exclude_service_accounts
    addresses = message.destinations.map(&:downcase)
    blocked = Accounts::Account.service.where(email: addresses).pluck(:email)
    return if blocked.empty?

    %i[to cc bcc].each do |field|
      recipients = Array(message.public_send(field)).reject { |email| blocked.include?(email.downcase) }
      message.public_send("#{field}=", recipients)
    end
    throw :abort if message.destinations.empty?
  end

  def recipient_locale(arg)
    account =
      if arg.is_a?(Accounts::Account) then arg
      elsif arg.respond_to?(:account) then arg.account
      elsif arg.respond_to?(:invited_by) then arg.invited_by
      end
    account&.effective_locale || I18n.default_locale
  end
end
