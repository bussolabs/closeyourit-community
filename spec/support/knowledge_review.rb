# frozen_string_literal: true

# CYRA-764: il revisore automatico gira dentro CreatePage/UpdatePage/Publish e parla col server AI
# di casa. Nelle prove è spento per difetto — le centinaia di spec che creano una pagina non devono
# sapere delle regole di formato — e si accende con il tag `knowledge_review: true`, dove si prova
# il revisore stesso o il suo innesto.
RSpec.configure do |config|
  config.before do |example|
    if example.metadata[:knowledge_review]
      # L'interruttore nasce SPENTO (fail-closed senza chiave): qui lo si accende, o il revisore vero
      # risponderebbe «spento dal god» a ogni esempio.
      Settings::Global.instance.update!(ai_knowledge_review_enabled: true)
    else
      allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))
    end
  end
end
