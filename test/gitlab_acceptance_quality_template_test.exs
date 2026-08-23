defmodule CiCdHarness.GitLabAcceptanceQualityTemplateTest do
  use ExUnit.Case, async: true

  @templates [
    Path.expand("../templates/gitlab/acceptance.yml", __DIR__),
    Path.expand("../templates/gitlab/cd.yml", __DIR__),
    Path.expand("../templates/gitlab/quality.yml", __DIR__)
  ]

  test "the GitLab adapters pin and execute the provider-neutral package" do
    predecessor_name = Enum.join(["gitlab", "ci", "cd", "harness"], "-")

    for path <- @templates do
      template = File.read!(path)

      assert template =~ ~s(CI_CD_HARNESS_REF: "v0.4.28")
      assert template =~ "https://git.agile-u.com/olivierg/ci-cd-harness.git"
      assert template =~ ".ci-cd-harness/priv/core/"
      refute template =~ predecessor_name
      refute template =~ ".ci-cd-harness/scripts/"
    end
  end

  test "the GitLab permit adapter preserves shared-runner admission" do
    template = File.read!(Path.expand("../templates/gitlab/permit.yml", __DIR__))

    assert template =~ ".ci_cd_host_permit:"
    assert template =~ ~s(CI_PERMIT_PROVIDER: "gitlab")
    assert template =~ "ci-with-permit"
    assert template =~ "/run/ci-permits/ci-permits.sock"
  end

  test "the acceptance adapter preserves the evidence and gate job graph" do
    template = File.read!(hd(@templates))

    assert template =~ "acceptance_fast:"
    assert template =~ "ACCEPTANCE_FAST_COMMAND"
    assert template =~ "pipeline_acceptance_report.sh staging"
    assert template =~ "acceptance_evidence:"
    assert template =~ "job: deploy_staging"
    assert template =~ "job: acceptance_fast"
    assert template =~ "acceptance_gate:"
    assert template =~ "job: acceptance_evidence"
    assert template =~ "publish_acceptance_report:"
  end

  test "the quality adapter preserves reusable budget and audit jobs" do
    template = File.read!(List.last(@templates))

    assert template =~ ".ci_cd_mix_cache:"
    assert template =~ ".ci_cd_exunit_test_budget:"
    assert template =~ ".ci_cd_exunit_test_value_audit:"
  end
end
