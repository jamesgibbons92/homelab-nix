# Applies clusters/sanzang/** through k3s's addon controller, so a push to main
# reaches the cluster on the same auto-upgrade timer as the rest of the system —
# no kubectl, no CI credential, nothing inbound. Replaces the manual
# `kubectl apply -f clusters/sanzang/<name>/` step.
#
# DANGER: the addon controller owns what it applies, so deleting a file here
# DELETES the resources it created. Six of these are PersistentVolumeClaims on
# local-path, which reclaims Delete — `git rm` of a config-storage.yaml or
# pvc.yaml destroys the data in it. Renaming a file is a delete plus a create.
# Same hazard class as the CRD note in modules/cloudnative-pg.nix.
#
# Manifests are still applied like `kubectl apply`, so anything without an
# explicit metadata.namespace lands in `default`.
{lib, ...}: let
  root = ../clusters/sanzang;

  # Jobs are immutable in spec.template, so re-applying an edited one fails.
  # Run this by hand when it needs to run.
  skip = ["storage/media-init-job.yaml"];

  isYaml = n: t: t == "regular" && lib.hasSuffix ".yaml" n;
  dirsIn = d: lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir d));

  yamlsIn = sub:
    lib.filter (p: !(lib.elem p skip))
    (map (f: "${sub}/${f}") (lib.attrNames (lib.filterAttrs isYaml (builtins.readDir (root + "/${sub}")))));

  paths = lib.concatMap yamlsIn (dirsIn root);

  # clusters/sanzang/niks3/ingress.yaml -> manifest name "niks3-ingress",
  # written as niks3-ingress.yaml. Distinct from the sops-rendered niks3.yaml.
  toEntry = p:
    lib.nameValuePair
    (lib.replaceStrings ["/" ".yaml"] ["-" ""] p)
    {source = root + "/${p}";};
in {
  services.k3s.manifests = lib.listToAttrs (map toEntry paths);
}
