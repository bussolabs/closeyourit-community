# frozen_string_literal: true

# Gating condiviso dei system spec che richiedono un browser reale (Stimulus deve connettersi).
# Estratto da select_combobox_spec / dismissable_menu_spec / board_keyboard_spec per non duplicare
# la registrazione del driver Chrome headless + il gate "Chrome disponibile?" + il before di setup.
#
# Un system spec JS si marca `js: true`: qui il driver si registra UNA volta e il before comune
# (skip se manca Chrome / driven_by / max_wait) si applica via hook su quella metadata. Così la CI
# Linux browserless del progetto (senza Chrome) auto-salta invece di diventare rossa; opt-in
# esplicito con JS_SYSTEM_SPECS=1.
# Misura della finestra con cui ogni system spec JS deve PARTIRE. Vive qui perché la usano in due:
# l'avvio del browser e il ripristino prima di ogni esempio (vedi il before più sotto).
FINESTRA_PREDEFINITA = [ 1400, 1600 ].freeze

Capybara.register_driver(:cyi_chrome_headless) do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-gpu")
  options.add_argument("--window-size=#{FINESTRA_PREDEFINITA.join(',')}")
  # CYRA-715 — console del browser leggibile dagli spec. Serve a provare che la Content Security
  # Policy, ora che blocca davvero, non stia bloccando anche cose nostre: un blocco non produce né
  # errore server né pagina rotta, solo una riga in console che senza questo nessuno leggerebbe.
  options.logging_prefs = { browser: "ALL" }
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

module JsSystemSupport
  # Chrome/Chromium disponibile? (app bundle macOS o binario nel PATH). Opt-in via JS_SYSTEM_SPECS=1.
  def chrome_available?
    return true if ENV["JS_SYSTEM_SPECS"].present?
    return true if File.exist?("/Applications/Google Chrome.app")

    %w[google-chrome google-chrome-stable chromium chromium-browser].any? do |bin|
      system("which #{bin} > /dev/null 2>&1")
    end
  end

  # Login condiviso ai flussi JS: dopo il submit attende che il POST di login (Turbo, asincrono)
  # completi e il cookie di sessione sia posato, prima di navigare altrove — altrimenti visit corre
  # e viene rimbalzato al login.
  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    expect(page).to have_no_css("[data-test='login-submit']", wait: 8)
  end
end

RSpec.configure do |config|
  config.include JsSystemSupport, type: :system

  # Setup comune ai system spec JS (`js: true`): salta senza Chrome, altrimenti guida col driver reale.
  config.before(:each, :js, type: :system) do
    skip "Chrome non disponibile: system spec js saltato (opt-in via JS_SYSTEM_SPECS=1)" unless chrome_available?
    driven_by(:cyi_chrome_headless)
    Capybara.default_max_wait_time = 8

    # La finestra si rimette alla misura di partenza PRIMA di ogni esempio. Capybara fra un esempio e
    # l'altro azzera la sessione — cookie, pagina — ma NON la misura della finestra: quella è del
    # browser, che resta acceso per tutto il processo. Un esempio che stringe a 390x844 per provare il
    # telefono (ui/tooltip_position_spec, member/global_search_spec) lascia quindi la finestra stretta
    # a chi viene dopo, e chi viene dopo trova la sidebar nascosta.
    #
    # Il guasto che ne nasce non somiglia alla causa: Capybara TROVA l'elemento (i selettori usano
    # `visible: :all`) e poi Selenium rifiuta di premerlo — `ElementNotInteractableError`, senza una
    # parola sulla misura della finestra. E dipende dall'ordine, quindi in locale non si vede quasi
    # mai: si vede in CI, dove gli shard mettono insieme file che in locale nessuno lancia insieme.
    # Rimettere la misura qui chiude la categoria intera, invece del singolo esempio che l'ha rivelata.
    page.current_window.resize_to(*FINESTRA_PREDEFINITA)
  end

  # On failure, print what the browser was really showing: CI keeps the screenshot on the runner
  # only, so the URL and page text are the one clue that reaches the log. Runs before the reset.
  config.after(:each, :js, type: :system) do |example|
    next unless example.exception

    lines = example.metadata[:extra_failure_lines] ||= []
    lines << "Browser URL: #{page.current_url}"
    lines << "Page text: #{page.text(:all).squish.truncate(1500)}"
  rescue StandardError => e
    warn "system failure diagnostics unavailable: #{e.class}: #{e.message}"
  ensure
    # Finish cable queries before Rails unpins the shared test connection. Otherwise
    # a subscription can deadlock with the next example's transactional fixtures.
    executor = ActionCable.server.worker_pool.executor
    Capybara.reset_sessions!
    ActionCable.server.restart
    raise "ActionCable workers did not stop before fixture teardown" unless executor.wait_for_termination(5)
  end
end
