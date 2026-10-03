# LiDAR reference for camera-mode scans: floor, object size, silhouette vs LiDAR, per-frame world drift.
import numpy as np, json, os, sys
from PIL import Image
sys.path.insert(0,os.path.dirname(__file__)); from hull import load, cam
def rect(xz,k=0):
    best=None
    for a in np.radians(np.arange(0,90,1.0)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=np.sort(xz@R.T,0)
        e=q[-1-k]-q[k]
        if best is None or e[0]*e[1]<best[0]: best=(e[0]*e[1],e)
    return sorted(best[1],reverse=True)
for d in sys.argv[1:]:
    ix,F=load(d); w,h=ix['width'],ix['height']; ark=ix['lockPlaneY']; anc=np.array(ix['lockSeed'])
    est=json.load(open(d+'/scan.json'))['estimate']; hullY=est['planeY']; c=np.array(est['center'])
    u=np.tile(np.arange(w),h); v=np.repeat(np.arange(h),w)
    P=[];fid=[]; frames=[i for i in range(len(F)) if F[i]['phase']==1]
    for i in frames:
        fx,fy,cx,cy,T=cam(F[i],w,h); dd=F[i]['sm'].astype(np.float32); cf=F[i]['sc']
        Q=np.stack([(u-cx)*dd/fx,-(v-cy)*dd/fy,-dd],1)@T[:3,:3].T+T[:3,3]
        ok=np.isfinite(dd)&(dd>0)&(cf>=1)&(np.hypot(Q[:,0]-c[0],Q[:,2]-c[2])<0.9)
        P.append(Q[ok]); fid.append(np.full(ok.sum(),i))
    P=np.concatenate(P); fid=np.concatenate(fid)
    r=np.hypot(P[:,0]-c[0],P[:,2]-c[2])
    ring=(r>0.45)&(r<0.85)&(abs(P[:,1]-ark)<0.15)
    floor=np.median(P[ring,1])
    obj=(r<0.4)&(P[:,1]>floor+0.01)&(P[:,1]<floor+0.6)
    O=P[obj]; H=np.percentile(O[:,1],99.5)-floor
    # widest extent: per 2 cm slice, 0.5% trimmed rect; report max over slices + base slice
    best=(0,0); slices=[]
    for y0 in np.arange(floor+0.01,floor+H,0.02):
        s=O[(O[:,1]>=y0)&(O[:,1]<y0+0.02)][:,[0,2]]
        if len(s)<200: continue
        L,W=rect(s,int(len(s)*0.005)); slices.append((y0-floor,L,W))
    Lm=max(x[1] for x in slices); Wm=max(x[2] for x in slices)
    # per-frame drift: centroid of each frame's top points (top 3 cm) in world xz
    top=O[:,1]>floor+H-0.03; ft=fid[obj][top]; Ot=O[top]
    cs=np.array([Ot[ft==i][:,[0,2]].mean(0) for i in np.unique(ft) if (ft==i).sum()>50])
    drift=np.linalg.norm(cs-cs.mean(0),axis=1)
    print(f"== {os.path.basename(d)} {est['shape']}  camera {100*est['length']:.1f} x {100*est['width']:.1f} x {100*est['height']:.1f}")
    print(f"   floor (rel. ARKit plane): LiDAR {100*(floor-ark):+.1f} cm   hull {100*(hullY-ark):+.1f} cm   -> camera height from LiDAR floor would be {100*(est['height']+hullY-floor):.1f}")
    print(f"   LiDAR object: height {100*H:.1f}  widest {100*Lm:.1f} x {100*Wm:.1f}  base(1-3cm) {100*slices[0][1]:.1f} x {100*slices[0][2]:.1f}")
    print(f"   top-centroid spread across {len(cs)} frames: median {100*np.median(drift):.2f} cm, p90 {100*np.percentile(drift,90):.2f} cm (pose jitter + view-dependent coverage)")
    # silhouette check: LiDAR object points projected per frame vs Vision mask
    out=[];
    for i in frames[::3]:
        p=f"{d}/images/{F[i]['t']:.6f}.jpg.mask.pgm"
        if not os.path.exists(p): continue
        m=np.array(Image.open(p))>0; K=F[i]['K'].reshape(3,3); sc=m.shape[1]/F[i]['res'][0]; T=F[i]['T'].reshape(4,4).T
        Pc=(O[fid[obj]==i]-T[:3,3])@T[:3,:3]
        if len(Pc)<100: continue
        dz=-Pc[:,2]; uu=np.round(Pc[:,0]*K[0,0]*sc/dz+(K[2,0]+.5)*sc-.5).astype(int); vv=np.round(-Pc[:,1]*K[1,1]*sc/dz+(K[2,1]+.5)*sc-.5).astype(int)
        ins=(uu>=0)&(uu<m.shape[1])&(vv>=0)&(vv<m.shape[0])
        out.append(1-m[vv[ins],uu[ins]].mean())
    print(f"   LiDAR object pixels outside the Vision mask: median {100*np.median(out):.1f} %  p90 {100*np.percentile(out,90):.1f} %  ({len(out)} frames)")
