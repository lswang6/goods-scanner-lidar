# Camera-only Phase 0 (2026-10-03). Usage: python3 hull.py <raw scan dir>...   (numpy only)
# Result on 10 device scans of the 40x30x30 box (LiDAR-depth silhouettes at 256x192, LiDAR-aided poses):
#   erode 0: L +0.0..+2.4, W -0.1..+3.2, H(edge) +0..+3.5 cm; erode 1: L -1.0..+1.6, W -1.3..+2.2 cm.
# Option A upper bound: visual hull from silhouettes only (+ ARKit poses + floor plane).
# Silhouette proxy = pixels whose LiDAR point is above the floor near the box (a "perfect" segmentation at depth res).
import numpy as np, json, glob, os, sys
def load(d):
    ix=json.load(open(d+'/frames.json')); w,h=ix['width'],ix['height']; n=w*h
    dt=np.dtype([('t','<f8'),('phase','u1'),('trk','u1'),('th','u1'),('fl','u1'),('T','<f4',(16,)),('K','<f4',(9,)),('res','<f4',(2,)),
                 ('raw','<f2',(n,)),('sm','<f2',(n,)),('rc','u1',(n,)),('sc','u1',(n,))])
    return ix,np.memmap(d+'/frames.bin',dtype=dt,mode='r',shape=(ix['count'],))
def cam(fr,w,h):
    K=fr['K'].reshape(3,3); fx=K[0,0]*w/fr['res'][0]; fy=K[1,1]*h/fr['res'][1]
    cx=(K[2,0]+.5)*w/fr['res'][0]-.5; cy=(K[2,1]+.5)*h/fr['res'][1]-.5
    return fx,fy,cx,cy,fr['T'].reshape(4,4).T
def run(d, src='sm', vox=0.005, stride=1, er=0):
    ix,F=load(d); w,h=ix['width'],ix['height']; fy0=ix['lockPlaneY']; seed=np.array(ix['lockSeed'])
    frames=[F[i] for i in range(len(F)) if F[i]['phase']==1][::stride]
    u=np.tile(np.arange(w),h); v=np.repeat(np.arange(h),w)
    # masks + rough center
    masks=[];allp=[]
    for fr in frames:
        fx,fy,cx,cy,T=cam(fr,w,h); dd=fr[src].astype(np.float32)
        P=np.stack([(u-cx)*dd/fx,-(v-cy)*dd/fy,-dd],1)@T[:3,:3].T+T[:3,3]
        ok=np.isfinite(dd)&(dd>0)
        obj=ok&(P[:,1]>fy0+0.02)&(np.hypot(P[:,0]-seed[0],P[:,2]-seed[2])<0.5)&(P[:,1]<seed[1]+0.3)
        m=obj.reshape(h,w)
        for _ in range(er): m=m&np.roll(m,1,0)&np.roll(m,-1,0)&np.roll(m,1,1)&np.roll(m,-1,1)
        masks.append((m,ok.reshape(h,w))); allp.append(P[obj])
    A=np.concatenate(allp); c=np.median(A[:,[0,2]],0)
    # 3D grid
    xs=np.arange(c[0]-0.4,c[0]+0.4,vox); zs=np.arange(c[1]-0.4,c[1]+0.4,vox); ys=np.arange(fy0+vox/2,fy0+0.5,vox)
    X,Y,Z=np.meshgrid(xs,ys,zs,indexing='ij'); G=np.stack([X.ravel(),Y.ravel(),Z.ravel()],1)
    keep=np.ones(len(G),bool)
    for fr,(m,ok) in zip(frames,masks):
        fx,fy,cx,cy,T=cam(fr,w,h); idx=np.nonzero(keep)[0]
        Pc=(G[idx]-T[:3,3])@T[:3,:3]; dz=-Pc[:,2]
        uu=np.round(Pc[:,0]*fx/np.maximum(dz,1e-6)+cx).astype(int); vv=np.round(-Pc[:,1]*fy/np.maximum(dz,1e-6)+cy).astype(int)
        ins=(dz>0.05)&(uu>=0)&(uu<w)&(vv>=0)&(vv<h)
        carve=np.zeros(len(idx),bool)
        carve[ins]=(~m[vv[ins],uu[ins]])&ok[vv[ins],uu[ins]]   # known background pixel -> carve; no-depth pixel -> unknown
        keep[idx[carve]]=False
    H=keep.reshape(len(xs),len(ys),len(zs))
    # footprint = columns occupied in the lowest 3 cm; rect fit by rotating calipers (min area)
    foot=H[:,:int(0.03/vox)+1,:].any(1); fi=np.argwhere(foot); xz=np.stack([xs[fi[:,0]],zs[fi[:,1]]],1)
    best=None
    for a in np.radians(np.arange(0,90,0.5)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=xz@R.T
        e=np.ptp(q,0)+vox; A_=e[0]*e[1]
        if best is None or A_<best[0]: best=(A_,a,e)
    L,W=sorted(best[2],reverse=True)
    # height: hull height near the footprint edge (inside 1-3 cm), where the visual-hull "roof" vanishes
    colh=np.where(H.any(1),(H.shape[1]-1-np.argmax(H[:,::-1,:],1))*vox+vox,0)
    def erode(m,k):
        for _ in range(k): m=m&np.roll(m,1,0)&np.roll(m,-1,0)&np.roll(m,1,1)&np.roll(m,-1,1)
        return m
    band=erode(foot,int(0.01/vox))&~erode(foot,int(0.03/vox))
    return L,W,np.median(colh[band]),np.percentile(colh[foot],95),len(frames)
if __name__=='__main__':
    for d in sys.argv[1:]:
        for er in (0,1):
            L,W,Hb,Hmax,n=run(d,'sm',er=er)
            print(f"{os.path.basename(d.rstrip('/'))} erode {er} frames {n:3d}  L {L*100:5.1f}  W {W*100:5.1f}  H(edge) {Hb*100:5.1f}  H(roof p95) {Hmax*100:5.1f}",flush=True)
