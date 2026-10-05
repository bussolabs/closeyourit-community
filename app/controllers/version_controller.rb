# Identità della build a runtime (tag/sha/build-time iniettati nel container via builder.args).
# Pubblico e non autenticato (come /up): usato dallo smoke-test CI per verificare che la versione
# live corrisponda al tag deployato. Eredita da ActionController::Base per saltare auth/org context.
class VersionController < ActionController::Base
  def show
    render json: App::Version.to_h
  end
end
