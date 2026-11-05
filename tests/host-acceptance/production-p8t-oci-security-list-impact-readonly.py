#!/usr/bin/env python3
"""P8T-L: OCI subnet security-list blast-radius inventory. Provider READ-ONLY."""
from __future__ import annotations
import datetime as dt
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode=True
os.umask(0o077)
HERE=Path(__file__).resolve().parent
REGEX=re.compile(r"ocid1\.[a-z][a-z0-9_-]*\.oc[0-9]+\.[a-z0-9.-]+\Z")
def load(name):
    sp=importlib.util.spec_from_file_location("p8t_"+name,HERE/name)
    if sp is None or sp.loader is None: raise RuntimeError("missing pinned helper")
    obj=importlib.util.module_from_spec(sp)
    sp.loader.exec_module(obj)
    return obj

def extra_get(kind, identity, region, *, vcn=None):
    """Allowlisted supplementary GET/list; provider mutations impossible."""
    if not REGEX.fullmatch(identity):
        return None
    if kind=="vcn":
        args=["network","vcn","get","--vcn-id",identity]
    elif kind=="subnets" and vcn and REGEX.fullmatch(vcn):
        args=["network","subnet","list","--compartment-id",identity,
              "--vcn-id",vcn,"--all"]
    elif kind=="ips":
        args=["network","private-ip","list","--subnet-id",identity,"--all"]
    else:
        return None
    try:
        p=subprocess.run(["oci",*args,"--region",region,"--output","json",
                          "--max-retries","0","--connection-timeout","4",
                          "--read-timeout","10"],
                         stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL,timeout=75,check=False)
        if p.returncode or not 0<len(p.stdout)<=1048576:
            return None
        data=json.loads(p.stdout)
        return data.get("data") if isinstance(data,dict) else None
    except (OSError,subprocess.TimeoutExpired,ValueError,UnicodeError):
        return None

def put_private(payload):
    folder=Path.home()/"vwoci-acceptance"
    folder.mkdir(mode=0o700,exist_ok=True)
    st=folder.lstat()
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid()
            or stat.S_IMODE(st.st_mode)!=0o700):
        raise RuntimeError("private mapping folder metadata mismatch")
    file=folder/("p8t-impact-"+dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                 +"-"+str(os.getpid())+".json")
    fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600)
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(payload,f,indent=2,sort_keys=True)
        f.write("\n")
    return file

def scan(sha, instance_id, region):
    cloud=load("production-p8t-oci-cloud-shell-readonly.py")
    p8t=cloud.module()
    if (not re.fullmatch("[0-9a-f]{40}",sha)
            or not REGEX.fullmatch(instance_id)
            or not instance_id.startswith("ocid1.instance.")
            or not cloud.REGION_RE.fullmatch(region)
            or shutil.which("oci") is None or not p8t.source_clean(sha)):
        print("BLOCKED: use exact clean pinned Cloud Shell checkout")
        return 2
    rows=[]
    private={"instance_id":instance_id,"subnets":[],"security_lists":[],
             "scope":"selected-instance-VCN-and-known-compartments-only"}
    violated=False
    try:
        inst=cloud.data_only(("compute","instance","get"),"--instance-id",
                             instance_id,region)
        if not isinstance(inst,dict) or inst.get("id")!=instance_id:
            raise RuntimeError("instance-identity-unverified")
        comp=inst.get("compartment-id")
        attached=cloud.data_only(("compute","vnic-attachment","list"),
            "--compartment-id",comp,region,extra=("--all",),instance_filter=instance_id)
        if not isinstance(attached,list) or len(attached)>64:
            raise RuntimeError("selected-instance-vnic-list-unavailable")
        vnics=[r.get("vnic-id") for r in attached if isinstance(r,dict)
               and r.get("lifecycle-state")=="ATTACHED"]
        if not 1<=len(vnics)<=8 or len(set(vnics))!=len(vnics):
            raise RuntimeError("attached-vnic-identity-incomplete")
        rows.append(("PASS","oci.selected-instance-and-attached-vnics"))
        subnet_ids=set()
        for vnic_id in vnics:
            vnic=cloud.data_only(("network","vnic","get"),
                                  "--vnic-id",vnic_id,region)
            subnet_id=vnic.get("subnet-id") if isinstance(vnic,dict) else None
            if not isinstance(subnet_id,str) or not REGEX.fullmatch(subnet_id):
                rows.append(("PENDING","oci.attached-vnic-subnet-unavailable"))
                continue
            if subnet_id in subnet_ids: continue
            subnet_ids.add(subnet_id)
            subnet=cloud.data_only(("network","subnet","get"),
                                   "--subnet-id",subnet_id,region)
            if not isinstance(subnet,dict) or subnet.get("id")!=subnet_id:
                rows.append(("PENDING","oci.subnet-identity-unavailable"))
                continue
            vcn_id=subnet.get("vcn-id")
            subnet_comp=subnet.get("compartment-id")
            lists=subnet.get("security-list-ids")
            if (not isinstance(lists,list) or not 1<=len(lists)<=12 or
                    any(not isinstance(s,str) or not REGEX.fullmatch(s) for s in lists)):
                rows.append(("PENDING","oci.subnet-security-list-attachment-unavailable"))
                continue
            rows.append(("PASS","oci.subnet-security-list-attachments-read"))
            scope={"subnet_id":subnet_id,"security_list_ids":lists,
                   "vcn_id":vcn_id,"other_subnet_ids_in_scanned_compartments":[]}
            private["subnets"].append(scope)
            offending=set()
            for sl_id in lists:
                data=cloud.data_only(("network","security-list","get"),
                                     "--security-list-id",sl_id,region)
                ingress=data.get("ingress-security-rules") if isinstance(data,dict) else None
                if not isinstance(ingress,list) or len(ingress)>1024:
                    rows.append(("PENDING","oci.security-list-read-incomplete"))
                    continue
                matches=[]
                for i,r in enumerate(ingress):
                    if not isinstance(r,dict): continue
                    marks=cloud.categorized_http_exposure(r,"security-list",p8t,{})
                    marks=tuple(x for x in marks if ".global-tcp" in x)
                    if marks: matches.append({"rule_index_for_review":i,"categories":marks})
                if matches:
                    violated=True
                    offending.add(sl_id)
                    ref="list-"+str(len(private["security_lists"])+1).zfill(2)
                    private["security_lists"].append({
                        "ref":ref,"security_list_id":sl_id,"subnet_id":subnet_id,
                        "display_name":data.get("display-name"),"rules":matches})
                    for family, mark in sorted({tuple(cat.split(".")[-2:])
                            for m in matches for cat in m["categories"]}):
                        rows.append(("BLOCKED","oci."+ref+"."+family+"."+mark))
            if not offending:
                rows.append(("PENDING","oci.no-global-violation-reobserved-in-this-subnet"))
            vcn=extra_get("vcn",vcn_id,region) if isinstance(vcn_id,str) else None
            vcn_comp=vcn.get("compartment-id") if isinstance(vcn,dict) else None
            default=vcn.get("default-security-list-id") if isinstance(vcn,dict) else None
            if isinstance(default,str):
                rows.append(("PASS","oci.vcn-default-security-list-identified"))
                if default in offending:
                    rows.append(("PENDING","oci.offending-list-is-vcn-default"))
            else:
                rows.append(("PENDING","oci.vcn-default-list-unavailable"))
            scanned=0
            other_subnets=set()
            for scope_comp in {subnet_comp,vcn_comp}-{None}:
                if not isinstance(scope_comp,str) or not REGEX.fullmatch(scope_comp):
                    continue
                all_subnets=extra_get("subnets",scope_comp,region,vcn=vcn_id)
                if not isinstance(all_subnets,list) or len(all_subnets)>2048:
                    rows.append(("PENDING","oci.other-subnets-list-unavailable"))
                    continue
                scanned+=1
                for other in all_subnets:
                    if not isinstance(other,dict): continue
                    sid=other.get("id")
                    attached_lists=other.get("security-list-ids")
                    if (isinstance(sid,str) and sid!=subnet_id
                            and isinstance(attached_lists,list)
                            and offending.intersection(attached_lists)):
                        other_subnets.add(sid)
            scope["other_subnet_ids_in_scanned_compartments"]=sorted(other_subnets)
            if other_subnets:
                rows.append(("PENDING","oci.offending-list-shared-with-other-subnets"))
            elif scanned:
                rows.append(("PASS","oci.no-other-subnets-seen-in-queried-compartments"))
            else:
                rows.append(("PENDING","oci.subnet-sharing-list-queries-unavailable"))
            rows.append(("PENDING","oci.other-compartments-not-exhaustively-verified"))
            ips=extra_get("ips",subnet_id,region)
            if isinstance(ips,list) and len(ips)<=4096:
                other={r.get("vnic-id") for r in ips if isinstance(r,dict)
                       and isinstance(r.get("vnic-id"),str)
                       and r["vnic-id"] not in vnics}
                scope["other_vnic_count_in_subnet"]=len(other)
                if other:
                    rows.append(("PENDING","oci.target-subnet-has-other-vnics"))
                elif ips and all(isinstance(r,dict) and r.get("vnic-id") for r in ips):
                    rows.append(("PASS","oci.no-other-vnics-in-subnet-private-ip-list"))
                else:
                    rows.append(("PENDING","oci.private-ip-vnic-list-incomplete"))
            else:
                rows.append(("PENDING","oci.private-ip-vnic-list-unavailable"))
    except Exception:
        rows.append(("PENDING","oci.impact-audit-provider-get-incomplete"))
    rows.append(("PENDING","oci.shared-resource-console-review-required"))
    rows.append(("NOT RUN","oci.no-provider-security-list-network-or-service-mutations"))
    path=put_private(private)
    print("Gate P8T-L - OCI security-list blast-radius READ-ONLY")
    for status,key in rows: print(f"{status:<10} {key}")
    outcome="BLOCKED" if violated else "HOLD"
    print(f"{outcome:<10} P8T-L only; prior OCI BLOCKED is not cleared by HOLD")
    print("Private resource mapping (do not share):",path)
    print("Share sanitized rows and P8T_IMPACT_EXIT only.")
    return 2 if violated else 0

if __name__=="__main__":
    if len(sys.argv)!=4:
        print("BLOCKED: expected SHA, disposable instance OCID, OCI region")
        raise SystemExit(2)
    raise SystemExit(scan(*sys.argv[1:]))
