defmodule CiCdHarness.GitLabCdTemplateTest do
  use ExUnit.Case, async: true

  @template Path.expand("../templates/gitlab/cd.yml", __DIR__)

  test "the GitLab adapter pins and executes the provider-neutral package" do
    template = File.read!(@template)

    assert template =~ ~s(CI_CD_HARNESS_REF: "v0.4.34")
    assert template =~ "https://git.agile-u.com/olivierg/ci-cd-harness.git"
    assert template =~ ".ci-cd-harness/priv/core/deploy_release_fast.sh"
    assert template =~ ".ci-cd-harness/priv/core/release_tag.sh"
    assert template =~ ".ci-cd-harness/priv/core/notify_deployment.sh"
    assert template =~ ".ci-cd-harness/priv/core/staging_release_smoke.sh"
  end

  test "production remains manual and downstream of staging verification" do
    template = File.read!(@template)

    assert template =~ "job: acceptance_gate"
    assert template =~ "job: staging_release_smoke"
    assert template =~ ~r/deploy_prod:.*?when: manual/s
  end
end
