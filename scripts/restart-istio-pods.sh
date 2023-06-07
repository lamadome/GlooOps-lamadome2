#!/bin/bash

context=$1
pods=$(istioctl ps --context $context | tail -n +2 | awk '{print $1}')
for pod in $pods
do
  IFS='.' read -r pod_name namespace <<< "$pod"
  kubectl --context $1 delete pod $pod_name -n $namespace
done
