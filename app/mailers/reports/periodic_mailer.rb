# frozen_string_literal: true

module Reports
  # Riepilogo periodico dei DATI (CYRA-160): traffico, errori e uptime del periodo. Gemello del
  # digest delle notifiche, con l'altra metà del mestiere: quello dice cosa è successo di nuovo,
  # questo dice come sta andando. La view vive sotto app/views/mails/reports/periodic_mailer/
  # (template_path proc in ApplicationMailer).
  class PeriodicMailer < ApplicationMailer
    def summary(account, organization, report)
      @account = account
      @organization = organization
      @report = report
      mail to: account.email,
           subject: t("reports.periodic.mailer.subject.#{report.cadence}", org: organization.name)
    end
  end
end
