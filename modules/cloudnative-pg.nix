# CloudNativePG operator — Postgres for niks3 (see modules/niks3.nix). Chosen
# over a hand-rolled Deployment because niks3's chart wants a Secret holding a
# libpq connection string under the key `uri`, which is exactly what CNPG
# publishes as `<cluster>-app`. The Cluster itself lives in the workload layer.
#
# Careful: the k3s addon controller owns what it deploys. Removing this module
# uninstalls the operator and takes the postgresql.cnpg.io CRDs with it — which
# deletes every Cluster, and with it the database. Same hazard as the namespace
# note in modules/media.nix.
{...}: {
  services.k3s.manifests.cloudnative-pg.content = {
    apiVersion = "helm.cattle.io/v1";
    kind = "HelmChart";
    metadata = {
      name = "cloudnative-pg";
      namespace = "kube-system";
    };
    spec = {
      repo = "https://cloudnative-pg.github.io/charts";
      chart = "cloudnative-pg";
      # Bump deliberately: https://cloudnative-pg.github.io/charts/index.yaml
      version = "0.29.1";
      targetNamespace = "cnpg-system";
      createNamespace = true;
    };
  };
}
