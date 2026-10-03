# Usage: python3 seeds.py <scan>... ; swiftc -O mask.swift -o mask && ./mask <scan>/seeds.txt ; python3 hull_rgb.py <scan>...
# Result 2026-10-03, 3 scans of the 40x30x30 box (140542/140612/140642), erode 0, H extrapolated to the edge:
#   40.6x31.4x30.5, 41.3x31.5x30.8, 40.7x31.6x31.2 cm (LiDAR on the same scans: 39.7x30.3x31.1, 41.1x31.6x31.2, 41.4x30.1x31.3).
#   Poses + floor plane are LiDAR-aided here; seed = LiDAR lock seed.
# Option A with real camera silhouettes: Apple Vision foreground masks (960x720) + ARKit poses + floor plane.
import numpy as np, json, os, sys
from PIL import Image
sys.path.insert(0,os.path.dirname(__file__)); from hull import load
def run(d, vox=0.004, er=0):
    ix,F=load(d); fy0=ix['lockPlaneY']; seed=np.array(ix['lockSeed'])
    views=[]
    for fr in F:
        p=f"{d}/images/{fr['t']:.6f}.jpg.mask.pgm"
        if fr['phase']!=1 or not os.path.exists(p): continue
        m=np.array(Image.open(p))>0
        for _ in range(er): m=m&np.roll(m,1,0)&np.roll(m,-1,0)&np.roll(m,1,1)&np.roll(m,-1,1)
        K=fr['K'].reshape(3,3); s=m.shape[1]/fr['res'][0]
        views.append((m,K[0,0]*s,K[1,1]*s,(K[2,0]+.5)*s-.5,(K[2,1]+.5)*s-.5,fr['T'].reshape(4,4).T))
    c=seed[[0,2]]
    xs=np.arange(c[0]-0.45,c[0]+0.45,vox); zs=np.arange(c[1]-0.45,c[1]+0.45,vox); ys=np.arange(fy0+vox/2,fy0+0.6,vox)
    X,Y,Z=np.meshgrid(xs,ys,zs,indexing='ij'); G=np.stack([X.ravel(),Y.ravel(),Z.ravel()],1).astype(np.float32)
    keep=np.ones(len(G),bool)
    for m,fx,fy,cx,cy,T in views:
        h,w=m.shape; idx=np.nonzero(keep)[0]
        Pc=(G[idx]-T[:3,3])@T[:3,:3]; dz=-Pc[:,2]
        uu=np.round(Pc[:,0]*fx/np.maximum(dz,1e-6)+cx).astype(int); vv=np.round(-Pc[:,1]*fy/np.maximum(dz,1e-6)+cy).astype(int)
        ins=(dz>0.05)&(uu>=0)&(uu<w)&(vv>=0)&(vv<h)
        carve=np.zeros(len(idx),bool); carve[ins]=~m[vv[ins],uu[ins]]
        keep[idx[carve]]=False
    H=keep.reshape(len(xs),len(ys),len(zs))
    foot=H[:,:int(0.03/vox)+1,:].any(1); fi=np.argwhere(foot); xz=np.stack([xs[fi[:,0]],zs[fi[:,1]]],1)
    best=None
    for a in np.radians(np.arange(0,90,0.5)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=xz@R.T
        lo,hi=np.percentile(q,[0.5,99.5],0); e=hi-lo+vox
        if best is None or e[0]*e[1]<best[0]: best=(e[0]*e[1],a,e)
    L,W=sorted(best[2],reverse=True)
    colh=np.where(H.any(1),(H.shape[1]-np.argmax(H[:,::-1,:],1))*vox,0)
    def erode(m,k):
        for _ in range(k): m=m&np.roll(m,1,0)&np.roll(m,-1,0)&np.roll(m,1,1)&np.roll(m,-1,1)
        return m
    band=erode(foot,int(0.01/vox))&~erode(foot,int(0.03/vox))
    # roof height vs distance from the footprint edge (erosion layers), linear fit over 0.4-4 cm -> intercept at the edge
    layers=[];cur=foot
    for k in range(12):
        nxt=erode(cur,1); layers.append(np.median(colh[cur&~nxt]) if (cur&~nxt).any() else np.nan); cur=nxt
    k=np.arange(1,11); dist=k*vox; hv=np.array(layers[1:11]); ok=np.isfinite(hv)
    H0=np.polyval(np.polyfit(dist[ok],hv[ok],1),0)
    return L,W,H0,np.median(colh[band]),len(views)
if __name__=='__main__':
    for d in sys.argv[1:]:
        for er in (0,2):
            L,W,Hb,Hc,n=run(d,er=er)
            print(f"{os.path.basename(d.rstrip('/'))} erode {er}px views {n:3d}  L {L*100:5.1f}  W {W*100:5.1f}  H(extrap) {Hb*100:5.1f}  H(band) {Hc*100:5.1f}",flush=True)
