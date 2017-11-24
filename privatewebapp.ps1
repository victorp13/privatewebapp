# Main variables
$location="West Europe"
$randomvalue=$(Get-Random)
$resourcegroup="rg" + $randomvalue
$gateway="gw" + $randomvalue
$webappname="wa" + $randomvalue
$ipname="ip" + $randomvalue
$vnet="vnet" + $randomvalue

# VM variables (optional resource)
$vmname="vm" + $randomvalue
$vmdns="dns" + $randomvalue
$vmip="vmip" + $randomvalue
$vmnic="vmnic" + $randomvalue
# VM credentials: MAKE SURE TO CHANGE THESE!
$vmuser = "vmusername"
$vmpassword = ConvertTo-SecureString "@Str0ngP4ssw0rd!" -AsPlainText -Force 

# Create a resource group
$rg = New-AzureRmResourceGroup -Name $resourcegroup -Location $location

# Create an App Service plan in Basic tier (required for ip restrictions)
New-AzureRmAppServicePlan -Name $webappname -Location $location -ResourceGroupName $rg.ResourceGroupName -Tier Basic

# Creates a web app
$webapp = New-AzureRmWebApp -ResourceGroupName $rg.ResourceGroupName -Name $webappname -Location $location -AppServicePlan $webappname

# Create a subnet for the application gateway
$subnetgateway = New-AzureRmVirtualNetworkSubnetConfig -Name gateway -AddressPrefix 10.0.0.0/24

# Create a subnet for the vm (optional)
$subnetvm = New-AzureRmVirtualNetworkSubnetConfig -Name vm -AddressPrefix 10.0.1.0/24

# Create a vnet for the application gateway
$vnet = New-AzureRmVirtualNetwork -Name $vnet -ResourceGroupName $rg.ResourceGroupName -Location $location -AddressPrefix 10.0.0.0/16 -Subnet $subnetgateway, $subnetvm


# Retrieve Subnets in order to get Subnet Ids
$subnetgateway = Get-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "gateway"
$subnetvm = Get-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "vm"

# Create a public IP address
$publicip = New-AzureRmPublicIpAddress -ResourceGroupName $rg.ResourceGroupName -name $ipname -location $location -AllocationMethod Dynamic

# Create a new IP configuration
$gipconfig = New-AzureRmApplicationGatewayIPConfiguration -Name gatewayIP01 -Subnet $subnetgateway

# Create a backend pool with the hostname of the web app
$pool = New-AzureRmApplicationGatewayBackendAddressPool -Name appGatewayBackendPool -BackendFqdns $webapp.HostNames

# Define the status codes to match for the probe
$match = New-AzureRmApplicationGatewayProbeHealthResponseMatch -StatusCode 200-399

# Create a probe with the PickHostNameFromBackendHttpSettings switch for web apps
$probeconfig = New-AzureRmApplicationGatewayProbeConfig -name webappprobe -Protocol Http -Path / -Interval 30 -Timeout 120 -UnhealthyThreshold 3 -PickHostNameFromBackendHttpSettings -Match $match

# Define the backend http settings
$poolSetting = New-AzureRmApplicationGatewayBackendHttpSettings -Name appGatewayBackendHttpSettings -Port 80 -Protocol Http -CookieBasedAffinity Disabled -RequestTimeout 120 -PickHostNameFromBackendAddress -Probe $probeconfig

# Create a new front-end port
$fp = New-AzureRmApplicationGatewayFrontendPort -Name frontendport01  -Port 80

# Create a new front end IP configuration for the Private IP
$fipconfigprivate = New-AzureRmApplicationGatewayFrontendIPConfig -Name fipconfig01 -Subnet $subnetgateway -PrivateIPAddress "10.0.0.12"

# Create a new front end IP configuration for the Public IP
$fipconfigpublic = New-AzureRmApplicationGatewayFrontendIPConfig -Name fipconfig02 -PublicIPAddress $publicip

# Create a new listener using the front-end private ip configuration and port created earlier
$listener = New-AzureRmApplicationGatewayHttpListener -Name listener01 -Protocol Http -FrontendIPConfiguration $fipconfigprivate -FrontendPort $fp

# Create a new rule
$rule = New-AzureRmApplicationGatewayRequestRoutingRule -Name rule01 -RuleType Basic -BackendHttpSettings $poolSetting -HttpListener $listener -BackendAddressPool $pool 

# Define the application gateway SKU to use
$sku = New-AzureRmApplicationGatewaySku -Name Standard_Small -Tier Standard -Capacity 2

# Create the application gateway
New-AzureRmApplicationGateway -Name $gateway -ResourceGroupName $resourcegroup -Location $location -BackendAddressPools $pool -BackendHttpSettingsCollection $poolSetting -Probes $probeconfig -FrontendIpConfigurations $fipconfigprivate, $fipconfigpublic -GatewayIpConfigurations $gipconfig -FrontendPorts $fp -HttpListeners $listener -RequestRoutingRules $rule -Sku $sku

# Retrieve public IP address again (will now be assigned)
$publicip=Get-AzureRmPublicIpAddress -Name $ipname -ResourceGroupName $resourcegroup

# Restrict access to public IP address (credits to Bram Stoop: https://bramstoop.com/2017/07/16/ipsecurityrestrictions-on-azure-app-services/)
$r = Get-AzureRmResource -ResourceGroupName $resourcegroup -ResourceType Microsoft.Web/sites/config -ResourceName $webappname/web -ApiVersion 2016-08-01
$p = $r.Properties
$p.ipSecurityRestrictions = @()
$restriction = @{}
$restriction.Add("ipAddress",$publicip.IpAddress)
$restriction.Add("subnetMask","255.255.255.255")
$p.ipSecurityRestrictions += $restriction

# Apply IP restriction to Web App
Set-AzureRmResource -ResourceGroupName $resourceGroup -ResourceType Microsoft.Web/sites/config -ResourceName $webappname/web -ApiVersion 2016-08-01 -PropertyObject $p -Force


# OPTIONAL part: Set up VM to test private connectivity
$PIP = New-AzureRmPublicIpAddress -Name $vmip -DomainNameLabel $vmdns -ResourceGroupName $resourcegroup -Location $location -AllocationMethod Dynamic
$NIC = New-AzureRmNetworkInterface -Name $vmnic -ResourceGroupName $resourcegroup -Location $location -SubnetId $subnetvm.Id -PublicIpAddressId $PIP.Id

# Define a credential 
$cred = New-Object System.Management.Automation.PSCredential ($vmuser, $vmpassword); 

# Create a virtual machine configuration
$vmConfig = New-AzureRmVMConfig -VMName $vmname -VMSize Standard_DS2 | `
    Set-AzureRmVMOperatingSystem -Windows -ComputerName $vmname -Credential $cred | `
    Set-AzureRmVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer `
    -Skus 2016-Datacenter -Version latest | Add-AzureRmVMNetworkInterface -Id $NIC.Id

New-AzureRmVM -ResourceGroupName $resourcegroup -Location $location -VM $vmConfig