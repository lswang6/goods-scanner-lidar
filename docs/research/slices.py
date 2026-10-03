import numpy as np, json, os, sys
from PIL import Image
sys.path.insert(0,os.path.dirname(__file__)); from hull import load
def hullgrid(d, below=0.15, above=0.6, vox=0.005):
    ix,F=load(d); fy0=ix['lockPlaneY']; seed=np.array(ix['lockSeed']); views=[]
    for fr in F:
        p=f"{d}/images/{fr['t']:.6f}.jpg.mask.pgm"
        if fr['phase']!=1 or not os.path.exists(p): continue
        m=np.array(Image.open(p))>0; K=fr['K'].reshape(3,3); s=m.shape[1]/fr['res'][0]
        views.append((m,K[0,0]*s,K[1,1]*s,(K[2,0]+.5)*s-.5,(K[2,1]+.5)*s-.5,fr['T'].reshape(4,4).T))
    c=seed[[0,2]]
    xs=np.arange(c[0]-0.4,c[0]+0.4,vox); zs=np.arange(c[1]-0.4,c[1]+0.4,vox); ys=np.arange(fy0-below+vox/2,fy0+above,vox)
    X,Y,Z=np.meshgrid(xs,ys,zs,indexing='ij'); G=np.stack([X.ravel(),Y.ravel(),Z.ravel()],1).astype(np.float32)
    keep=np.ones(len(G),bool); seen=np.zeros(len(G),np.int32)
    for m,fx,fy,cx,cy,T in views:
        h,w=m.shape; idx=np.nonzero(keep)[0]
        Pc=(G[idx]-T[:3,3])@T[:3,:3]; dz=-Pc[:,2]
        uu=np.round(Pc[:,0]*fx/np.maximum(dz,1e-6)+cx).astype(int); vv=np.round(-Pc[:,1]*fy/np.maximum(dz,1e-6)+cy).astype(int)
        ins=(dz>0.05)&(uu>=0)&(uu<w)&(vv>=0)&(vv<h)
        carve=np.zeros(len(idx),bool); carve[ins]=~m[vv[ins],uu[ins]]
        seen[idx[ins]]+=1; keep[idx[carve]]=False
    keep&=seen>=(len(views)+1)//2
    return keep.reshape(len(xs),len(ys),len(zs)),xs,ys,zs,fy0,len(views)
def rect(xz,vox):
    best=None
    for a in np.radians(np.arange(0,90,1.0)):
        R=np.array([[np.cos(a),np.sin(a)],[-np.sin(a),np.cos(a)]]); q=xz@R.T
        lo,hi=np.percentile(q,[0.5,99.5],0); e=hi-lo+vox
        if best is None or e[0]*e[1]<best[0]: best=(e[0]*e[1],e)
    return sorted(best[1],reverse=True)
if __name__=="__main__":
 for d in sys.argv[1:]:
    H,xs,ys,zs,fy0,n=hullgrid(d)
    print(f"== {os.path.basename(d)} views {n}  (y rel. ARKit floor, cm: cross-section L x W)")
    for j in range(0,len(ys),4):
        sl=H[:,j:j+4,:].any(1); fi=np.argwhere(sl)
        if len(fi)<5: continue
        xz=np.stack([xs[fi[:,0]],zs[fi[:,1]]],1); L,W=rect(xz,0.005)
        print(f"   y {100*(ys[j]-fy0):+6.1f}  {100*L:5.1f} x {100*W:5.1f}")
