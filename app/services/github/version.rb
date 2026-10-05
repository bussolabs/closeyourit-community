# frozen_string_literal: true

module Github
  # Stabilità di un tag di versione, per decidere l'environment target del binding
  # (tag stabile → production, pre-release → staging). Coerente con rules/ci.md:
  # `v1.2.3` stabile; `v1.2.3-beta` / `-rc1` / `-alpha` pre-release.
  module Version
    module_function

    # Stabile = semver senza suffisso pre-release (dopo il core X.Y.Z, prima del build-metadata `+`).
    def stable?(tag)
      core = tag.to_s.strip.sub(/\Av/i, "")
      return false if core.empty?

      core.split("+", 2).first.exclude?("-")
    end
  end
end
