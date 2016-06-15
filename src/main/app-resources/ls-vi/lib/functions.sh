#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_NO_URL=5
ERR_NO_PRD=8
ERR_GDAL_VRT=10
ERR_MAP_BANDS=15
ERR_OTB_BUNDLETOPERFECTSENSOR=20
ERR_DN2REF_4=25
ERR_DN2REF_3=25
ERR_DN2REF_2=25
ERR_GDAL_VRT2=30
ERR_GDAL_TRANSLATE=35
ERR_GDAL_WARP=40
ERR_GDAL_TRANSLATE=45
ERR_GDAL_ADDO=50
ERR_PUBLISH=55

# add a trap to exit gracefully
function cleanExit ()
{
  local retval=$?
  local msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_NO_URL}) msg="The Landsat 8 product online resource could not be resolved";;
    ${ERR_NO_PRD}) msg="The Landsat 8 product online resource could not be retrieved";;
    ${ERR_GDAL_VRT}) msg="Failed to create the RGB VRT";;
    ${ERR_MAP_BANDS}) msg="Failed to map RGB bands";;
    ${ERR_OTB_BUNDLETOPERFECTSENSOR}) msg="Failed to apply BundleToPerfectSensor OTB operator";;
    ${ERR_DN2REF_4}) msg="Failed to convert DN to reflectance";;
    ${ERR_DN2REF_3}) msg="Failed to convert DN to reflectance";;
    ${ERR_DN2REF_2}) msg="Failed to convert DN to reflectance";;
    ${ERR_GDAL_VRT2}) msg="Failed to create VRT with panchromatic bands";;
    ${ERR_GDAL_TRANSLATE}) msg="Failed to apply gdal_translate";;
    ${ERR_GDAL_WARP}) msg="Failed to warp";;
    ${ERR_GDAL_TRANSLATE2}) msg="Failed to apply gdal_translate";;
    ${ERR_ADDO}) msg="Failed to create levels";;
    ${ERR_PUBLISH}) msg="Failed to publish the results";;
    *) msg="Unknown error";;
  esac

  [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
  exit ${retval}
}

function setOTBenv() {
    
  . /etc/profile.d/otb.sh
  export otb_ram=4096

}

function setGDALEnv() {

  export GDAL_HOME=/usr/local/gdal-t2/
  export PATH=$GDAL_HOME/bin/:$PATH
  export LD_LIBRARY_PATH=$GDAL_HOME/lib/:$LD_LIBRARY_PATH
  export GDAL_DATA=$GDAL_HOME/share/gdal

}

function url_resolver() {

  local url=""
  local reference="$1"
  
  read identifier path < <( opensearch-client -m EOP  "${reference}" identifier,wrsLongitudeGrid | tr "," " " )
  [ -z "${path}" ] && path="$( echo ${identifier} | cut -c 4-6)"
  row="$( echo ${identifier} | cut -c 7-9)"

  url="http://storage.googleapis.com/earthengine-public/landsat/L8/${path}/${row}/${identifier}.tar.bz"

  [ -z "$( curl -s --head "${url}" | head -n 1 | grep "HTTP/1.[01] [23].." )" ] && return 1

  echo "${url}"

}

function getGain() {

  local band=$1
  local product_id=$2

  gain=$( cat ${product_id}/*_MTL.txt | grep REFLECTANCE_MULT_BAND_${band} | cut -d "=" -f 2 | tr -d " " )

  echo ${gain}

}

function getOffset() {

  local band=$1
  local product_id=$2
 
  offset=$( cat ${product_id}/*_MTL.txt | grep REFLECTANCE_ADD_BAND_${band} | cut -d "=" -f 2 | tr -d " " )

  echo ${offset}

}

function DNtoReflectance() {

  local band=$1
  local base_name=$2

  gain=$( getGain ${band} ${base_name} )
  offset=$( getOffset ${band} ${base_name} )

  otbcli_BandMath \
    -il ${base_name}/${base_name}_B${band}.TIF \
    -exp "${gain} * im1b1 + ${offset}" \
    -out ${base_name}/REFLECTANCE_B${band}.TIF

  return $?
}

function calcVegetation() {
  local index=$1
  local base_name=$2

  case $index in
    [LSWI]*)
      band1=5
      band2=6
      ;;
    [NBR]*)
      band1=5
      band2=7
      ;;
    [NDVI]*)
      band1=5
      band2=4
      ;;
    [MNDWI]*)
      band1=3
      band2=6
      ;;

  esac

  otbcli_BandMath \
    -il ${base_name}/REFLECTANCE_B${band1}.TIF \
    ${base_name}/REFLECTANCE_B${band2}.TIF \
    -exp " im1b1 >= 0 && im1b1 <= 1 && im2b1 >= 0 && im2b1 <= 1 ? ( im1b1 - im2b1 ) / ( im1b1 + im2b1 ) : 0  " \
    -out ${base_name}/${base_name}_${index}.TIF

  gdalwarp \
    -r cubic \
    -wm 8192 \
    -multi \
    -srcnodata "0 0 0" \
    -dstnodata "0 0 0" \
    -dstalpha \
    -wo OPTIMIZE_SIZE=TRUE \
    -wo UNIFIED_SRC_NODATA=YES \
    -t_srs EPSG:4326 \
    -co TILED=YES\
    -co COMPRESS=LZW\
    ${base_name}/${base_name}_${index}.TIF \
    ${base_name}/${base_name}_${index}_4326.TIF

  rm -f ${base_name}/${base_name}_${index}.TIF
   
  mv ${base_name}/${base_name}_${index}_4326.TIF ${base_name}/${base_name}_${index}.TIF
}

function metadata() {

  local xpath="$1"
  local value="$2"
  local target_xml="$3"
 
  xmlstarlet ed -L \
    -N A="http://www.opengis.net/opt/2.1" \
    -N B="http://www.opengis.net/om/2.0" \
    -N C="http://www.opengis.net/gml/3.2" \
    -N D="http://www.opengis.net/eop/2.1" \
    -u  "${xpath}" \
    -v "${value}" \
    ${target_xml}
 
}

function main() {

  # set OTB environment
  setOTBenv

  setGDALEnv

  cd ${TMPDIR}

  num_steps=14

  while read input
  do 
    ciop-log "INFO" "(1 of ${num_steps}) Retrieve Landsat 8 product from ${input}"

    read identifier startdate enddate < <( opensearch-client ${input} identifier,startdate,enddate | tr "," " " )
    online_resource="$( url_resolver ${input} )"
    [ -z "${online_resource}" ] && return ${ERR_NO_URL} 

    local_resource="$( echo ${online_resource} | ciop-copy -U -O ${TMPDIR} - )"
    [ -z "${local_resource}" ] && return ${ERR_NO_PRD}  
 
    ciop-log "INFO" "(2 of ${num_steps}) Extract ${identifier}"
    
    mkdir ${identifier}
    tar jxf ${local_resource} -C ${identifier} || return ${ERR_EXTRACT} 

    ciop-log "INFO" "(3 of ${num_steps}) Conversion of DN to reflectance"    

    # SWIR1
    DNtoReflectance 6 ${identifier} || return ${ERR_DNTOREF}

    # NIR
    DNtoReflectance 5 ${identifier} || return ${ERR_DNTOREF}

    # SWIR2
    DNtoReflectance 7 ${identifier} || return ${ERR_DNTOREF}

    # Red
    DNtoReflectance 4 ${identifier} || return ${ERR_DNTOREF}

    # Green
    DNtoReflectance 3 ${identifier} || return ${ERR_DNTOREF}

    ciop-log "INFO" "(4 of ${num_steps}) Process vegetation indices LSWI, NBR, NDVI and MNDWI"
    for index in LSWI NBR NDVI MNDWI
    do 
  
      calcVegetation ${index} ${identifier} || return ${ERR_CALC_VI}

      result="${TMPDIR}/${identifier}/$( echo ${identifier} | sed 's/LC8/LV8/' )_${index}"
      mv ${TMPDIR}/${identifier}/${identifier}_${index}.TIF ${result}.TIF

      ciop-log "INFO" "Publish vegeatation index ${index}"
      ciop-publish -m ${result}.TIF

      # set product type
      metadata \
        "//A:EarthObservation/D:metaDataProperty/D:EarthObservationMetaData/D:productType" \
        "LV8_${index}" \
        ${target_xml}

      # set processor name
      metadata \
        "//A:EarthObservation/D:metaDataProperty/D:EarthObservationMetaData/D:processing/D:ProcessingInformation/D:processorName" \
        "dcs-landsat8-vegetation-index" \
        ${target_xml}

      metadata \
        "//A:EarthObservation/D:metaDataProperty/D:EarthObservationMetaData/D:processing/D:ProcessingInformation/D:processorVersion" \
        "1.0" \
        ${target_xml}

      # set processor name
      metadata \
        "//A:EarthObservation/D:metaDataProperty/D:EarthObservationMetaData/D:processing/D:ProcessingInformation/D:nativeProductFormat" \
        "GEOTIFF" \
        ${target_xml}

      # set processor name
      metadata \
        "//A:EarthObservation/D:metaDataProperty/D:EarthObservationMetaData/D:processing/D:ProcessingInformation/D:processingCenter" \
        "Terradue Cloud Platform" \
        ${target_xml}
  
      # set startdate
      metadata \
        "//A:EarthObservation/B:phenomenonTime/C:TimePeriod/C:beginPosition" \
        "${startdate}" \
        ${target_xml}

      # set stopdate
      metadata \
        "//A:EarthObservation/B:phenomenonTime/C:TimePeriod/C:endPosition" \
        "${enddate}" \
        ${target_xml}   
  
      # set orbit direction
      metadata \
        "//A:EarthObservation/B:procedure/D:EarthObservationEquipment/D:acquisitionParameters/D:Acquisition/D:orbitDirection" \
        "DESCENDING" \
        ${target_xml}

      [ -z "${path}" ] && path="$( echo ${identifier} | cut -c 4-6)"
      row="$( echo ${identifier} | cut -c 7-9)"

      # set path
      metadata \
        "//A:EarthObservation/B:procedure/D:EarthObservationEquipment/D:acquisitionParameters/D:Acquisition/D:wrsLongitudeGrid" \
        "${path}" \
        ${target_xml} 

      # set row
      metadata \
        "//A:EarthObservation/B:procedure/D:EarthObservationEquipment/D:acquisitionParameters/D:Acquisition/D:wrsLatitudeGrid" \
        "${row}" \
        ${target_xml} 
      
    done

  done

}

