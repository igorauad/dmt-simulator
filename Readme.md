# DMT Simulator

This repository contains a functional Discrete Multitone (DMT) simulator
featuring different channel equalization schemes. The components of the
simulation are organized within the `lib` folder.

## Pre-requisites

In order to properly use this DMT simulator, the companion repository
[igorauad/gfast-channel](https://github.com/igorauad/gfast-channel) must be
cloned at the
parent folder. In the end, the following folder structure must be provided. The
`gfast-channel/data` folder is where the main script of the `gfast-channel`
 repository stores
the channel responses that it generates using G.fast channel models.

````
├── dmt-simulator
    └── lib
├── gfast-channel
    └── data
````

To do so, starting at the root folder of the current repository, run the
following commands:

```
cd ../
git clone https://github.com/igorauad/gfast-channel.git
cd gfast-channel
matlab -nojvm < generate_all.m
```

The last step above runs the script `generate_all.m`, which saves the files
containing the individual responses of each G.fast loop topology in the
aforementioned `data` folder.
