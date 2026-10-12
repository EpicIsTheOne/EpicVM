import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from local_lan import configure
configure(sys.argv[1],'192.168.1.178','https://portal.example',18443,18444,12020)
