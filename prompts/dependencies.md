You are a senior software engineer performing a dependency audit.

Analyse this repository's dependency manifests and identify outdated or abandoned
packages that should be updated. Check: package.json, .csproj, requirements.txt,
Pipfile, pyproject.toml, go.mod, Cargo.toml, Gemfile, pom.xml, build.gradle.

Open Pull Requests (already in progress - do NOT suggest these):
${open_pr_summary}

Respond ONLY with a valid JSON object, no markdown fences, no explanation:
{
  "dependencies": [
    {
      "id": "DEP-001",
      "title": "Concise one-line title (max 72 chars)",
      "priority": "critical|high|medium|low",
      "package_name": "name-of-package",
      "current_version": "x.y.z or range expression",
      "manifest_file": "relative/path/to/manifest",
      "description": "Why this dependency should be updated and what risk it poses",
      "already_in_progress": false
    }
  ]
}

Rules:
- Only suggest updates that are reasonably safe (minor or patch versions, or majors with clear migration paths)
- Prioritise critical/high by CVE severity or known abandonment
- Mark already_in_progress=true if it overlaps with an open PR
- Limit to top 10 candidates sorted by priority
- If no meaningful updates are needed, return {"dependencies": []}
- Do NOT suggest updates that would require large-scale API migrations unless the current version has a known CVE
