## This script is used to run training test on AmlArc-enabled compute


# init
init_env(){
    set -x
    export SUBSCRIPTION="${SUBSCRIPTION:-6560575d-fa06-4e7d-95fb-f962e74efd7a}"  
    export RESOURCE_GROUP="${RESOURCE_GROUP:-azureml-examples-rg}"  
    export WORKSPACE="${WORKSPACE_NAME:-main-amlarc}"  # $((1 + $RANDOM % 100))
    export LOCATION="${LOCATION:-eastus}"
    export ARC_CLUSTER_PREFIX="${ARC_CLUSTER_NAME:-amlarc-cluster-arc}"
    export AKS_CLUSTER_PREFIX="${AKS_CLUSTER_NAME:-amlarc-cluster-aks}"
    export AMLARC_ARC_RELEASE_TRAIN="${AMLARC_ARC_RELEASE_TRAIN:-experimental}"
    export AMLARC_ARC_RELEASE_NAMESPACE="${AMLARC_ARC_RELEASE_NAMESPACE:-azureml}"
    export EXTENSION_NAME="${EXTENSION_NAME:-amlarc-extension}"
    export EXTENSION_TYPE="${EXTENSION_TYPE:-Microsoft.AzureML.Kubernetes}"
}

install_tools(){
    set -x

    apt-get update -y 
    apt-get install sudo -y
    sudo apt-get install curl -y 
    sudo apt-get install python3-pip -y 
    sudo apt-get install python3 -y
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

    az extension add -n connectedk8s --yes
    az extension add -n k8s-extension --yes
    az extension add -n ml --yes

    curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl \
    && chmod +x ./kubectl  \
    && sudo mv ./kubectl /usr/local/bin/kubectl  

    pip3 install azureml-core 
}

waitForResources(){
    available=false
    max_retries=60
    sleep_seconds=5
    RESOURCE=$1
    NAMESPACE=$2
    for i in $(seq 1 $max_retries); do
        if [[ ! $(kubectl wait --for=condition=available ${RESOURCE} --all --namespace ${NAMESPACE}) ]]; then
            sleep ${sleep_seconds}
        else
            available=true
            break
        fi
    done
    
    echo "$available"
}

prepare_attach_compute_py(){
echo '
import sys
from azureml.core.compute import KubernetesCompute, ComputeTarget
from azureml.core.workspace import Workspace
from azureml.exceptions import ComputeTargetException

def main():
  
  print("args:", sys.argv)
  
  sub_id=sys.argv[1]
  rg=sys.argv[2]
  ws_name=sys.argv[3]
  k8s_compute_name = sys.argv[4]
  resource_id = sys.argv[5]
  
  ws = Workspace.get(name=ws_name,subscription_id=sub_id,resource_group=rg)
  
  try:
    # check if already attached
    k8s_compute = KubernetesCompute(ws, k8s_compute_name)
    print("compute already existed. will detach and re-attach it")
    k8s_compute.detach()
  except ComputeTargetException:
    print("compute not found")

  k8s_attach_configuration = KubernetesCompute.attach_configuration(resource_id=resource_id)
  k8s_compute = ComputeTarget.attach(ws, k8s_compute_name, k8s_attach_configuration)
  #k8s_compute.wait_for_completion(show_output=True)
  print("compute status:", k8s_compute.get_status())

if __name__ == "__main__":
    main()
' > attach_compute.py
}

# setup compute resources
setup_compute(){
    set -x -e

    VM_SKU="${1:-Standard_NC12}"
    COMPUTE_NAME="${2:-gpu-cluster}"
    MIN_COUNT="${3:-4}"
    MAX_COUNT="${4:-8}"

    ARC_CLUSTER_NAME=$(echo ${ARC_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')
    AKS_CLUSTER_NAME=$(echo ${AKS_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')

    # create resource group
    az group create \
        --subscription $SUBSCRIPTION \
        -l "$LOCATION" \
        -n "$RESOURCE_GROUP" 

    # create aks cluster
    az aks create \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --enable-cluster-autoscaler \
        --node-count $MIN_COUNT \
        --min-count $MIN_COUNT \
        --max-count $MAX_COUNT \
        --node-vm-size ${VM_SKU} \
        --generate-ssh-keys 

    # get aks kubeconfig
    az aks get-credentials \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --overwrite-existing

    # attach cluster to Arc
    az connectedk8s connect \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --name $ARC_CLUSTER_NAME 

    # Wait for resources in ARC ns
    waitSuccessArc="$(waitForResources deployment azure-arc)"
    if [ "${waitSuccessArc}" == false ]; then
        echo "deployment is not avilable in namespace - azure-arc"
    fi

    # install extension
    az k8s-extension create \
        --cluster-name $ARC_CLUSTER_NAME \
        --cluster-type connectedClusters \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $EXTENSION_NAME \
        --extension-type $EXTENSION_TYPE \
        --scope cluster \
        --release-train $AMLARC_ARC_RELEASE_TRAIN \
        --configuration-settings  enableTraining=True allowInsecureConnections=True
    
    # Wait for resources in amlarc-arc ns
    waitSuccessArc="$(waitForResources deployment $AMLARC_ARC_RELEASE_NAMESPACE)"
    if [ "${waitSuccessArc}" == false ]; then
        echo "deployment is not avilable in namespace - $AMLARC_ARC_RELEASE_NAMESPACE"
    fi

    # create workspace
    az ml workspace show \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --workspace-name $WORKSPACE || \
    az ml workspace create \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --workspace-name $WORKSPACE 

    # attach compute
    ARC_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Kubernetes/connectedClusters/$ARC_CLUSTER_NAME"
    python3 attach_compute.py \
        "$SUBSCRIPTION" "$RESOURCE_GROUP" \
        "$WORKSPACE" "$COMPUTE_NAME" "$ARC_RESOURCE_ID"

}

# check compute resources
check_compute(){
    set -x +e

    VM_SKU="${1:-Standard_NC12}"
    COMPUTE_NAME="${2:-gpu-cluster}"

    ARC_CLUSTER_NAME=$(echo ${ARC_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')
    AKS_CLUSTER_NAME=$(echo ${AKS_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')

    # check aks
    az aks show \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME 

    # check arc
    az connectedk8s show \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $ARC_CLUSTER_NAME 

    # check extension
    az k8s-extension show \
        --cluster-name $ARC_CLUSTER_NAME \
        --cluster-type connectedClusters \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $EXTENSION_NAME \

    # check ws
    az ml workspace show \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --workspace-name $WORKSPACE

    # check compute
    az ml compute show \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --workspace-name $WORKSPACE \
        --name $COMPUTE_NAME
    
}

# cleanup
clean_up_compute(){
    set -x +e

    VM_SKU="${1:-Standard_NC12}"

    ARC_CLUSTER_NAME=$(echo ${ARC_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')
    AKS_CLUSTER_NAME=$(echo ${AKS_CLUSTER_PREFIX}-${VM_SKU} | tr -d '_')

    # delete arc
    az connectedk8s delete \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $ARC_CLUSTER_NAME \
        --yes

    # delete aks
    az aks delete \
        --subscription $SUBSCRIPTION \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --yes

}

# run test
run_test(){
    set -x
    JOB_YML="${1:-jobs/train/fastai/mnist/job.yml}"

    SRW=" --subscription $SUBSCRIPTION --resource-group $RESOURCE_GROUP --workspace-name $WORKSPACE "

    run_id=$(az ml job create $SRW -f $JOB_YML --query name -o tsv)
    az ml job stream $SRW -n $run_id
    status=$(az ml job show $SRW -n $run_id --query status -o tsv)
    echo $status
    if [[ $status == "Completed" ]]
    then
        echo "Job completed"
    elif [[ $status ==  "Failed" ]]
    then
        echo "Job failed"
        exit 1
    else 
        echo "Job status not failed or completed"
        exit 2
    fi
}


if [ "$0" = "$BASH_SOURCE" ]; then
    $@
fi



