# per image: landscape pixel of the locked seed (box top center) -> list for the Vision masker
import numpy as np, json, sys, os
sys.path.insert(0,os.path.dirname(__file__)); from hull import load
for d in sys.argv[1:]:
    ix,F=load(d); seed=np.array(ix['lockSeed']); out=open(d+'/seeds.txt','w')
    for fr in F:
        p=f"{d}/images/{fr['t']:.6f}.jpg"
        if not os.path.exists(p): continue
        K=fr['K'].reshape(3,3); s=960/fr['res'][0]; T=fr['T'].reshape(4,4).T
        Pc=(seed-T[:3,3])@T[:3,:3]; dz=-Pc[2]
        u=Pc[0]*K[0,0]*s/dz+(K[2,0]+.5)*s-.5; v=-Pc[1]*K[1,1]*s/dz+(K[2,1]+.5)*s-.5
        out.write(f"{p} {u:.1f} {v:.1f}\n")
