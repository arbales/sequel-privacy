# FAQ

**1. Why don't you just assign policies to constants, rather than passing a symbol?**
I tried this initially, but I wanted to capture the name of the policy/constant 
for use in logging and errors.

**2. Why don't you create a Model.for_actor Dataset method instead of Model.for_vc?**
You should create one VC for each request, you don't want to accidentally be 
creating VCs for other users later in your request lifecycle.
